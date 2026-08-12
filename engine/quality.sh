#!/usr/bin/env bash
# engine/quality.sh — DETERMINISTIC code-quality metrics over a set of files.
#
# WHY THIS FILE EXISTS. `.chief/verify.sh` is a pass/fail test oracle: it answers
# "did the gates exit 0", nothing more. That is a reward shape with a documented
# blind spot — tests come back in seconds, while the maintainability damage
# (duplication, ballooning functions, deep nesting, shotgun decomposition) shows
# up in weeks. This tool is the SECOND, MEASURED axis: it turns a file set into a
# metric record that a ratchet can compare across two revisions of the same repo.
#
# THREE RULES IT WILL NOT BREAK.
#   1. NO MODEL JUDGMENT. Every number here comes from awk over text. A model
#      scoring a model's work reintroduces exactly the blind spot we are closing.
#   2. NO HIDDEN ZEROES. A metric we cannot compute for a language is reported in
#      `unmeasured` with a reason — never emitted as 0, never silently dropped. A
#      metric that vanishes is worse than one that is openly absent, because a
#      ratchet reads a vanished metric as "nothing got worse".
#   3. DETERMINISTIC OUTPUT. Same inputs -> byte-identical JSON. No timestamps, no
#      absolute paths, no host-specific values, every list sorted. The record is
#      meant to be committed as a baseline and diffed by humans.
#
# METRIC FAMILIES (after SlopCodeBench's deterministic measures):
#   size          files · source_lines · added_lines/removed_lines (diff mode)
#   complexity    functions · function_length_mean/max · max_nesting_depth
#   duplication   duplicate_blocks · duplicate_line_pct
#   decomposition single_use_functions  (a function with exactly one call site —
#                 the over-decomposition signal: "helper" churn nobody reuses)
#   violations    lint_violations       (only where a linter is actually present)
#
# LANGUAGE-AWARE, DEGRADING HONESTLY. The core (source lines, duplication by
# normalized-line hashing, nesting by brace/indent heuristic) is language-agnostic
# and ALWAYS runs. The richer per-language analyzers (function extraction, lint)
# run only where one exists and the toolchain is installed; everything else lands
# in `unmeasured`.
#
# All of it is heuristic by construction — text, not parse trees. That is a
# deliberate trade: a heuristic applied IDENTICALLY to both sides of a comparison
# still ranks them correctly, and it costs no toolchain, no network, no new hard
# dependency beyond the `jq` the engine already requires.
#
# bash 3.2: no associative arrays, no ${var^^}, no mapfile, no process
# substitution in the hot paths. awk (BWK/`awk` on macOS, gawk on Linux) does the
# scanning; nothing here is gawk-only.
set -uo pipefail

QUALITY_SCHEMA="chief.quality/1"
# Duplication window: N consecutive NORMALIZED source lines form a block. 6 is the
# common floor for "this is a copy, not a coincidence". Recorded in the output so a
# baseline is never compared against a record computed with a different window.
QUALITY_DUP_WINDOW="${CHIEF_QUALITY_DUP_WINDOW:-6}"
# shellcheck severity for the lint family. Lower = stricter = noisier.
QUALITY_SHELLCHECK_SEVERITY="${CHIEF_QUALITY_SHELLCHECK_SEVERITY:-warning}"

qq_die()  { echo "chief quality: $*" >&2; exit 2; }
qq_note() { [ "${QQ_QUIET:-0}" = "1" ] || echo "chief quality: $*" >&2; }

qq_usage() {
  cat <<EOF
chief quality — deterministic code-quality metrics (no model judgment anywhere).

Usage:
  chief quality measure [options] [FILE...]

  FILE...              repo-relative paths to measure. With none given, use
                       --files-from or --changed.

Options:
  --changed BASE       file set = git diff --name-only BASE...HEAD (existing files
                       only); also enables added_lines/removed_lines
  --files-from FILE    read newline-separated paths ("-" = stdin)
  --rev REV            read file CONTENT at git revision REV instead of the working
                       tree (the base side of a ratchet comparison). Paths that do
                       not exist at REV are reported in scope.absent_at_rev
  --root DIR           repo root (default: git toplevel, else cwd)
  --window N           duplication block size in normalized lines (default $QUALITY_DUP_WINDOW)
  --no-lint            skip the lint family entirely (reported as unmeasured)
  -o, --out FILE       write the JSON record here (default: stdout)
  -q, --quiet          suppress progress notes on stderr
  -h, --help           this message

Output: one JSON object, keys sorted, byte-identical for identical inputs.
Exit: 0 on success, 2 on a usage/environment error. Measuring never blocks —
the ratchet that CONSUMES this record is what blocks (see docs/verify-hook.md).
EOF
}

# ── language + analyzer classification ───────────────────────────────────────
# Prints "<language> <analyzer-family>". Families:
#   shell · clike · python  -> a function analyzer exists
#   none                    -> core metrics only; functions reported UNMEASURED
#   data                    -> not source at all; excluded from every metric
qq_classify() {
  case "$1" in
    *.sh|*.bash|*.ksh|*.zsh)                echo "shell shell" ;;
    *.c|*.h)                                echo "c clike" ;;
    *.cc|*.cpp|*.cxx|*.hpp|*.hh)            echo "cpp clike" ;;
    *.java)                                 echo "java clike" ;;
    *.js|*.jsx|*.mjs|*.cjs)                 echo "javascript clike" ;;
    *.ts|*.tsx)                             echo "typescript clike" ;;
    *.go)                                   echo "go clike" ;;
    *.rs)                                   echo "rust clike" ;;
    *.swift)                                echo "swift clike" ;;
    *.kt|*.kts)                             echo "kotlin clike" ;;
    *.cs)                                   echo "csharp clike" ;;
    *.scala)                                echo "scala clike" ;;
    *.php)                                  echo "php clike" ;;
    *.py)                                   echo "python python" ;;
    *.rb)                                   echo "ruby none" ;;
    *.pl|*.pm)                              echo "perl none" ;;
    *.lua)                                  echo "lua none" ;;
    *.ex|*.exs)                             echo "elixir none" ;;
    *.hs)                                   echo "haskell none" ;;
    *.erl)                                  echo "erlang none" ;;
    *.sql)                                  echo "sql none" ;;
    *.json)                                 echo "json data" ;;
    *.yml|*.yaml)                           echo "yaml data" ;;
    *.toml)                                 echo "toml data" ;;
    *.md|*.markdown)                        echo "markdown data" ;;
    *.txt|*.csv|*.tsv|*.lock|*.log)         echo "text data" ;;
    *.html|*.htm|*.xml|*.svg)               echo "markup data" ;;
    *.css|*.scss|*.less)                    echo "stylesheet data" ;;
    *.png|*.jpg|*.jpeg|*.gif|*.pdf|*.ico)   echo "binary data" ;;
    *)
      # No extension to go on — ask the shebang before giving up. This is how the
      # engine's own `bin/chief` gets measured as shell rather than "unknown".
      case "$(head -n 1 "$2" 2>/dev/null)" in
        '#!'*sh*)                           echo "shell shell" ;;
        '#!'*python*)                       echo "python python" ;;
        '#!'*node*)                         echo "javascript clike" ;;
        '#!'*ruby*)                         echo "ruby none" ;;
        '#!'*perl*)                         echo "perl none" ;;
        *)                                  echo "unknown none" ;;
      esac ;;
  esac
}

# ── awk programs, written out once per invocation ────────────────────────────
qq_write_awk() {
  cat > "$QQ_TMP/perfile.awk" <<'AWK'
# Per-file scanner. -v fam=shell|clike|python|none
# Emits tagged records on stdout:
#   S <sloc>              source lines (non-blank, non-comment-only)
#   N <max-nesting>       max nesting depth (brace or indent heuristic)
#   F <name> <length>     one per function found (family-dependent)
#   L <lineno> <text>     one normalized source line, for the duplication pass
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

function scanbraces(s,   i, ch) {
  for (i = 1; i <= length(s); i++) {
    ch = substr(s, i, 1)
    if (ch == "{")      { sawbrace = 1; depth++; if (depth > maxd) maxd = depth }
    else if (ch == "}") { sawbrace = 1; if (depth > 0) depth-- }
  }
}

BEGIN {
  sloc = 0; depth = 0; maxd = 0; inblk = 0
  fnname = ""; fnstart = 0; fnbase = 0; fnind = 0
  ni = 0; maxind = 0; sawbrace = 0; prevcode = 0
  split("if for while switch catch do else return try with func function new delete typeof await yield case default", KWL, " ")
  for (i in KWL) KW[KWL[i]] = 1
}

{
  raw = $0
  code = raw

  # ── comments out ───────────────────────────────────────────────────────────
  if (fam == "clike") {
    while (1) {
      if (inblk) {
        p = index(code, "*/")
        if (p == 0) { code = ""; break }
        code = substr(code, p + 2); inblk = 0
      } else {
        p = index(code, "/*")
        if (p == 0) break
        rest = substr(code, p + 2)
        q = index(rest, "*/")
        if (q == 0) { code = substr(code, 1, p - 1); inblk = 1; break }
        code = substr(code, 1, p - 1) " " substr(rest, q + 2)
      }
    }
    sub(/\/\/.*$/, "", code)
  } else if (code ~ /^[ \t]*(#|\/\/|--)/) {
    code = ""                      # whole-line comment in every other family
  }

  if (trim(code) == "") next       # blank or comment-only: not source, not dup input
  sloc++

  # ── structural view: string literals and shell expansions blanked out, so a
  #    brace or keyword inside a string never moves the nesting depth ──────────
  st = code
  if (fam == "shell") { gsub(/\$\{[^}]*\}/, "V", st); gsub(/\$\([^)]*\)/, "V", st) }
  gsub(/"[^"]*"/, "S", st)
  gsub(/'[^']*'/, "S", st)
  if (fam == "shell" || fam == "python" || fam == "none") sub(/[ \t]#.*$/, "", st)

  match(raw, /^[ \t]*/); ws = substr(raw, 1, RLENGTH); indent = 0
  for (i = 1; i <= length(ws); i++) indent += (substr(ws, i, 1) == "\t") ? 8 : 1

  d0 = depth

  # ── function closes, indent families ───────────────────────────────────────
  # BEFORE the open check, not after: `def b():` at the same indent both ENDS the
  # previous function and STARTS a new one, and a close that ran later would eat
  # every sibling definition in the file.
  if (fam == "python" && fnname != "" && NR > fnstart && indent <= fnind) {
    printf "F\t%s\t%d\n", fnname, prevcode - fnstart + 1
    fnname = ""
  }

  # ── function opens ─────────────────────────────────────────────────────────
  if (fam == "shell") {
    if (fnname == "" && st ~ /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\([ \t]*\)[ \t]*\{/) {
      head = st; sub(/\(.*$/, "", head); sub(/^[ \t]*function[ \t]+/, "", head)
      cand = trim(head)
      if (cand != "") { fnname = cand; fnstart = NR; fnbase = d0 }
    }
  } else if (fam == "clike") {
    if (fnname == "" && st ~ /\{[ \t]*$/) {
      head = st; sub(/\{[ \t]*$/, "", head); cand = ""
      if (head ~ /=>[ \t]*$/) {                       # const foo = (a) => {
        sub(/[ \t]*=>[ \t]*$/, "", head); sub(/\([^()]*\)[ \t]*$/, "", head)
        sub(/[ \t]*=[ \t]*$/, "", head)
        n = split(head, W2, /[^A-Za-z0-9_$]+/); cand = W2[n]
      } else if (head ~ /\)/) {                       # name(args) ... {
        p = index(head, "(")
        if (p > 1) { pre = substr(head, 1, p - 1); n = split(pre, W2, /[^A-Za-z0-9_$]+/); cand = W2[n] }
      }
      if (cand != "" && !(cand in KW)) { fnname = cand; fnstart = NR; fnbase = d0 }
    }
  } else if (fam == "python") {
    if (fnname == "" && st ~ /^[ \t]*(async[ \t]+)?def[ \t]+[A-Za-z_]/) {
      head = st; sub(/^[ \t]*(async[ \t]+)?def[ \t]+/, "", head); sub(/[^A-Za-z0-9_].*$/, "", head)
      if (head != "") { fnname = head; fnstart = NR; fnind = indent }
    }
  }

  # ── nesting ────────────────────────────────────────────────────────────────
  if (fam == "shell") {
    nt = split(st, T, /[^A-Za-z0-9_]+/)
    for (i = 1; i <= nt; i++) {
      tok = T[i]
      if (tok == "if" || tok == "for" || tok == "while" || tok == "until" || tok == "case" || tok == "select") {
        depth++; if (depth > maxd) maxd = depth
      } else if (tok == "fi" || tok == "done" || tok == "esac") {
        if (depth > 0) depth--
      }
    }
    scanbraces(st)
  } else if (fam == "clike") {
    scanbraces(st)
  } else if (fam == "python") {
    if (indent > (ni > 0 ? ind[ni] : -1)) { ni++; ind[ni] = indent; if (ni - 1 > maxind) maxind = ni - 1 }
    else { while (ni > 0 && ind[ni] > indent) ni-- }
  } else {
    scanbraces(st)                                     # unknown: try braces …
    if (indent > (ni > 0 ? ind[ni] : -1)) { ni++; ind[ni] = indent; if (ni - 1 > maxind) maxind = ni - 1 }
    else { while (ni > 0 && ind[ni] > indent) ni-- }    # … and indent, decided at END
  }

  # ── function closes, brace families ────────────────────────────────────────
  # AFTER the structural scan, because the closing brace is on this very line.
  if (fnname != "" && (fam == "shell" || fam == "clike") && depth <= fnbase) {
    printf "F\t%s\t%d\n", fnname, NR - fnstart + 1
    fnname = ""
  }

  # ── normalized line for the duplication pass ───────────────────────────────
  # Whitespace collapsed so re-indentation is not mistaken for a rewrite; lines
  # that are pure punctuation ("}", ");") or trivially short are dropped, because
  # they repeat everywhere and would drown the real copies.
  norm = trim(code); gsub(/[ \t]+/, " ", norm)
  if (length(norm) >= 4 && norm ~ /[A-Za-z0-9_]/) printf "L\t%d\t%s\n", NR, norm

  prevcode = NR
}

END {
  if (fnname != "") printf "F\t%s\t%d\n", fnname, prevcode - fnstart + 1
  printf "S\t%d\n", sloc
  if (fam == "python")                      printf "N\t%d\n", maxind
  else if (fam == "none" && sawbrace == 0)  printf "N\t%d\n", maxind
  else                                      printf "N\t%d\n", maxd
}
AWK

  cat > "$QQ_TMP/dup.awk" <<'AWK'
# Duplication over the whole file set. Input (tab-separated, grouped by file):
#   <file-index> <lineno> <normalized text>
# A block is W consecutive normalized lines OF THE SAME FILE. Blocks are keyed by
# their exact normalized text, so the comparison is order-independent and needs no
# hashing (and therefore no host-dependent hash function).
# Emits:
#   BLOCKS   <distinct block signatures occurring more than once>
#   LINES    <total normalized lines>
#   DUPLINES <total normalized lines covered by a repeated block>
#   D <file-index> <normalized lines of that file covered by a repeated block>
BEGIN { FS = "\t"; cur = ""; n = 0; gi = 0; ni = 0 }
{
  if ($1 != cur) { cur = $1; n = 0 }
  n++; gi++
  buf[n] = $3; gidx[n] = gi; gfile[gi] = $1
  if (n >= W) {
    key = ""
    for (i = n - W + 1; i <= n; i++) key = key buf[i] "\001"
    cnt[key]++
    ni++; ikey[ni] = key
    for (i = n - W + 1; i <= n; i++) imem[ni, i - (n - W)] = gidx[i]
  }
}
END {
  blocks = 0
  for (k in cnt) if (cnt[k] > 1) blocks++
  for (j = 1; j <= ni; j++) {
    if (cnt[ikey[j]] <= 1) continue
    for (i = 1; i <= W; i++) dup[imem[j, i]] = 1
  }
  duplines = 0
  for (g in dup) { duplines++; perfile[gfile[g]]++ }
  printf "BLOCKS\t%d\n", blocks
  printf "LINES\t%d\n", gi
  printf "DUPLINES\t%d\n", duplines
  for (f in perfile) printf "D\t%s\t%d\n", f, perfile[f]
}
AWK

  cat > "$QQ_TMP/single.awk" <<'AWK'
# Decomposition: a function whose name appears exactly ONCE outside its own
# definition line is single-use — the over-decomposition signal. Reference
# counting is textual (identifier tokens across every normalized source line of
# the set), so an indirect call through a variable is not seen. Heuristic, but
# applied identically to both sides of a comparison.
# Input 1: names file, one function name per line. Input 2: the normalized lines.
BEGIN { FS = "\t" }
NR == FNR { if ($0 != "") names[$0] = 1; next }
{
  line = $3
  gsub(/[^A-Za-z0-9_]/, " ", line)
  n = split(line, T, " ")
  for (i = 1; i <= n; i++) if (T[i] in names) refs[T[i]]++
}
END {
  single = 0
  for (nm in names) if (refs[nm] == 2) single++      # 1 definition + exactly 1 use
  printf "%d\n", single
}
AWK
}

# ── measure ──────────────────────────────────────────────────────────────────
qq_measure() {
  local root="" rev="" changed_base="" files_from="" out="" do_lint=1
  local argv_files
  argv_files=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --root)        [ $# -ge 2 ] || qq_die "--root needs a directory";  root="$2";         shift 2 ;;
      --rev)         [ $# -ge 2 ] || qq_die "--rev needs a revision";    rev="$2";          shift 2 ;;
      --changed)     [ $# -ge 2 ] || qq_die "--changed needs a base";    changed_base="$2"; shift 2 ;;
      --files-from)  [ $# -ge 2 ] || qq_die "--files-from needs a file"; files_from="$2";   shift 2 ;;
      --window)      [ $# -ge 2 ] || qq_die "--window needs a number";   QUALITY_DUP_WINDOW="$2"; shift 2 ;;
      --no-lint)     do_lint=0; shift ;;
      -o|--out)      [ $# -ge 2 ] || qq_die "--out needs a file";        out="$2";          shift 2 ;;
      -q|--quiet)    QQ_QUIET=1; shift ;;
      -h|--help)     qq_usage; return 0 ;;
      --)            shift; break ;;
      -*)            qq_die "unknown option: $1" ;;
      *)             argv_files="$argv_files$1
"; shift ;;
    esac
  done
  while [ $# -gt 0 ]; do argv_files="$argv_files$1
"; shift; done

  command -v jq >/dev/null 2>&1 || qq_die "jq is required"
  case "$QUALITY_DUP_WINDOW" in ''|*[!0-9]*) qq_die "--window must be a positive integer" ;; esac
  [ "$QUALITY_DUP_WINDOW" -ge 2 ] || qq_die "--window must be >= 2"

  [ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  [ -d "$root" ] || qq_die "not a directory: $root"
  cd "$root" || qq_die "cannot cd to $root"

  # ── the file set ───────────────────────────────────────────────────────────
  local list="$QQ_TMP/files.raw"
  : > "$list"
  [ -n "$argv_files" ] && printf '%s' "$argv_files" >> "$list"
  if [ -n "$files_from" ]; then
    if [ "$files_from" = "-" ]; then cat >> "$list"
    else [ -f "$files_from" ] || qq_die "no such file: $files_from"; cat "$files_from" >> "$list"; fi
  fi
  if [ -n "$changed_base" ]; then
    git rev-parse --verify --quiet "$changed_base" >/dev/null 2>&1 \
      || qq_die "not a revision: $changed_base"
    git diff --name-only "$changed_base"...HEAD >> "$list" 2>/dev/null \
      || qq_die "git diff against $changed_base failed"
  fi
  grep -v '^[[:space:]]*$' "$list" | LC_ALL=C sort -u > "$QQ_TMP/files.sorted"

  # ── content side: working tree, or materialized from a revision ────────────
  local content="$root" absent=0 f
  if [ -n "$rev" ]; then
    git rev-parse --verify --quiet "$rev" >/dev/null 2>&1 || qq_die "not a revision: $rev"
    content="$QQ_TMP/rev"
    mkdir -p "$content"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      # Ask FIRST, write second: a path that does not exist at REV (a file this
      # branch added) is an honest scope fact, not an empty file to be measured.
      if git cat-file -e "$rev:$f" 2>/dev/null; then
        mkdir -p "$content/$(dirname "$f")" 2>/dev/null
        git show "$rev:$f" > "$content/$f" 2>/dev/null || absent=$((absent + 1))
      else
        absent=$((absent + 1))
      fi
    done < "$QQ_TMP/files.sorted"
  fi

  # ── per-file scan ──────────────────────────────────────────────────────────
  local rows="$QQ_TMP/rows.tsv" norms="$QQ_TMP/norm.tsv" names="$QQ_TMP/names.txt"
  local shellfiles="$QQ_TMP/shell.txt" rec="$QQ_TMP/rec"
  : > "$rows"; : > "$norms"; : > "$names"; : > "$shellfiles"

  local idx=0 rel abs cls lang fam sloc nest fcount fmax fsum
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    abs="$content/$rel"
    [ -f "$abs" ] || continue
    cls="$(qq_classify "$rel" "$abs")"
    lang="${cls%% *}"; fam="${cls##* }"

    # Not source, or binary content that would poison every scanner: recorded as
    # excluded scope rather than measured as a pile of zeroes.
    if [ "$fam" != "data" ] && ! LC_ALL=C grep -qI . "$abs" 2>/dev/null && [ -s "$abs" ]; then
      lang="binary"; fam="data"
    fi
    if [ "$fam" = "data" ]; then
      printf '%s\t%s\tdata\t0\t0\t0\t0\t0\t0\t-1\tnot-source\n' "$rel" "$lang" >> "$rows"
      continue
    fi

    idx=$((idx + 1))
    awk -v fam="$fam" -f "$QQ_TMP/perfile.awk" "$abs" > "$rec" 2>/dev/null

    sloc="$(awk -F'\t' '$1=="S"{print $2}' "$rec")"; sloc="${sloc:-0}"
    nest="$(awk -F'\t' '$1=="N"{print $2}' "$rec")"; nest="${nest:-0}"
    if [ "$fam" = "none" ]; then
      fcount=-1; fmax=-1; fsum=-1
    else
      fcount="$(awk -F'\t' '$1=="F"{n++} END{print n+0}' "$rec")"
      fmax="$(awk -F'\t' '$1=="F"{if($3>m)m=$3} END{print m+0}' "$rec")"
      fsum="$(awk -F'\t' '$1=="F"{s+=$3} END{print s+0}' "$rec")"
      awk -F'\t' '$1=="F"{print $2}' "$rec" >> "$names"
    fi
    awk -F'\t' -v i="$idx" '$1=="L"{printf "%s\t%s\t%s\n", i, $2, $3}' "$rec" >> "$norms"
    [ "$fam" = "shell" ] && printf '%s\n' "$rel" >> "$shellfiles"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t0\t-1\tpending\n' \
      "$rel" "$lang" "$fam" "$sloc" "$fcount" "$fmax" "$fsum" "$nest" >> "$rows"
  done < "$QQ_TMP/files.sorted"

  qq_note "measured $idx source file(s)"

  # ── duplication ────────────────────────────────────────────────────────────
  local dupblocks=0 normlines=0 duplines=0
  : > "$QQ_TMP/dup.perfile"
  if [ -s "$norms" ]; then
    awk -v W="$QUALITY_DUP_WINDOW" -f "$QQ_TMP/dup.awk" "$norms" > "$QQ_TMP/dup.out"
    dupblocks="$(awk -F'\t' '$1=="BLOCKS"{print $2}' "$QQ_TMP/dup.out")"
    normlines="$(awk -F'\t' '$1=="LINES"{print $2}' "$QQ_TMP/dup.out")"
    duplines="$(awk -F'\t' '$1=="DUPLINES"{print $2}' "$QQ_TMP/dup.out")"
    awk -F'\t' '$1=="D"{print $2"\t"$3}' "$QQ_TMP/dup.out" | LC_ALL=C sort -n > "$QQ_TMP/dup.perfile"
  fi
  dupblocks="${dupblocks:-0}"; normlines="${normlines:-0}"; duplines="${duplines:-0}"

  # ── decomposition ──────────────────────────────────────────────────────────
  local single=0
  if [ -s "$names" ] && [ -s "$norms" ]; then
    LC_ALL=C sort -u "$names" > "$QQ_TMP/names.uniq"
    single="$(awk -f "$QQ_TMP/single.awk" "$QQ_TMP/names.uniq" "$norms")"
  fi
  single="${single:-0}"

  # ── lint (only where a linter genuinely exists) ────────────────────────────
  local lint_tool="null" have_shellcheck=0
  if [ "$do_lint" = "1" ] && command -v shellcheck >/dev/null 2>&1; then
    have_shellcheck=1; lint_tool='"shellcheck"'
  fi
  : > "$QQ_TMP/lint.tsv"
  if [ "$have_shellcheck" = "1" ] && [ -s "$shellfiles" ]; then
    ( cd "$content" && tr '\n' '\0' < "$QQ_TMP/shell.txt" \
        | xargs -0 shellcheck -f gcc -S "$QUALITY_SHELLCHECK_SEVERITY" -- 2>/dev/null ) \
      | awk -F: 'NF>=4 {c[$1]++} END{for (f in c) printf "%s\t%d\n", f, c[f]}' \
      | LC_ALL=C sort > "$QQ_TMP/lint.tsv"
  fi

  # Fold per-file duplicate lines + lint counts back into the rows, and record a
  # REASON for every unmeasured lint cell so the JSON can explain itself.
  awk -F'\t' -v OFS='\t' \
      -v dupfile="$QQ_TMP/dup.perfile" -v lintfile="$QQ_TMP/lint.tsv" \
      -v shellfile="$QQ_TMP/shell.txt" -v haveSC="$have_shellcheck" -v dolint="$do_lint" '
    BEGIN {
      while ((getline line < dupfile) > 0)  { split(line, a, "\t"); dl[a[1] + 0] = a[2] + 0 }
      while ((getline line < lintfile) > 0) { split(line, a, "\t"); lv[a[1]] = a[2] + 0 }
      while ((getline line < shellfile) > 0) issh[line] = 1
      i = 0
    }
    {
      if ($3 != "data") { i++; $9 = dl[i] + 0 }
      if ($3 == "data")                            { $10 = -1; $11 = "not-source" }
      else if (issh[$1] && dolint == 1 && haveSC)  { $10 = lv[$1] + 0; $11 = "" }
      else if (dolint == 0)                        { $10 = -1; $11 = "lint-disabled" }
      else if (issh[$1])                           { $10 = -1; $11 = "shellcheck-not-installed" }
      else                                         { $10 = -1; $11 = "no-linter-configured" }
      print
    }' "$rows" > "$QQ_TMP/rows.final"

  # ── added / removed lines (diff mode on the working tree only) ─────────────
  local added="null" removed="null" numstat
  if [ -n "$changed_base" ] && [ -z "$rev" ]; then
    numstat="$(git diff --numstat "$changed_base"...HEAD 2>/dev/null \
      | awk -F'\t' '$1 ~ /^[0-9]+$/ {a += $1; r += $2} END{printf "%d %d\n", a + 0, r + 0}')"
    added="${numstat%% *}"; removed="${numstat##* }"
  fi

  local revmode=false
  [ -n "$rev" ] && revmode=true

  # ── assemble ───────────────────────────────────────────────────────────────
  local json
  json="$(
    LC_ALL=C sort "$QQ_TMP/rows.final" | jq -Rn -S \
      --arg schema "$QUALITY_SCHEMA" \
      --argjson window "$QUALITY_DUP_WINDOW" \
      --argjson lint_tool "$lint_tool" \
      --argjson dupblocks "$dupblocks" \
      --argjson normlines "$normlines" \
      --argjson duplines "$duplines" \
      --argjson single "$single" \
      --argjson added "$added" \
      --argjson removed "$removed" \
      --argjson absent "$absent" \
      --argjson revmode "$revmode" '
      def n0: if . == null then 0 else . end;
      def r2: (. * 100 | round) / 100;
      [ inputs | select(length > 0) | split("\t") ]
      | map({
          path:  .[0],
          language: .[1],
          family: .[2],
          source_lines: (.[3] | tonumber),
          functions: (if (.[4] | tonumber) < 0 then null else (.[4] | tonumber) end),
          function_length_max: (if (.[5] | tonumber) < 0 then null else (.[5] | tonumber) end),
          function_length_sum: (if (.[6] | tonumber) < 0 then null else (.[6] | tonumber) end),
          max_nesting_depth: (.[7] | tonumber),
          duplicate_lines: (.[8] | tonumber),
          lint_violations: (if (.[9] | tonumber) < 0 then null else (.[9] | tonumber) end),
          lint_reason: (.[10] // "")
        })
      | (map(select(.family != "data"))) as $src
      | (map(select(.family == "data")))  as $data
      | ($src | map(select(.functions != null))) as $fn
      | ($fn | map(.functions) | add | n0) as $nfn
      | {
          schema: $schema,
          config: { dup_window: $window, lint_tool: $lint_tool, rev_mode: $revmode },
          scope: {
            files: (($src | length) + ($data | length)),
            source_files: ($src | length),
            absent_at_rev: (if $revmode then $absent else null end),
            excluded: ( $data | group_by(.language)
                        | map({ language: .[0].language, files: length, reason: "not source" })
                        | sort_by(.language) )
          },
          totals: {
            files: ($src | length),
            source_lines: ($src | map(.source_lines) | add | n0),
            added_lines: $added,
            removed_lines: $removed,
            functions: (if ($fn | length) == 0 then null else $nfn end),
            function_length_mean: (
              if ($fn | length) == 0 or $nfn == 0 then null
              else ((($fn | map(.function_length_sum) | add | n0) / $nfn) | r2) end),
            function_length_max: (if ($fn | length) == 0 then null else ($fn | map(.function_length_max) | max | n0) end),
            max_nesting_depth: (if ($src | length) == 0 then null else ($src | map(.max_nesting_depth) | max | n0) end),
            duplicate_blocks: $dupblocks,
            duplicate_lines: $duplines,
            duplicate_line_pct: (if $normlines == 0 then 0 else (($duplines * 100 / $normlines) | r2) end),
            normalized_lines: $normlines,
            single_use_functions: (if ($fn | length) == 0 then null else $single end),
            lint_violations: (
              ($src | map(select(.lint_violations != null))) as $l
              | if ($l | length) == 0 then null else ($l | map(.lint_violations) | add | n0) end)
          },
          unmeasured: (
            ( $src | map(select(.functions == null)) | group_by(.language)
              | map(. as $g | ["functions", "single_use_functions", "function_length_mean", "function_length_max"]
                    | map({ metric: ., language: $g[0].language, files: ($g | length),
                            reason: "no function analyzer for this language" })) | add // [] )
            + ( $src | map(select(.lint_violations == null)) | group_by([.language, .lint_reason])
              | map({ metric: "lint_violations", language: .[0].language, files: length,
                      reason: (.[0].lint_reason
                               | if . == "shellcheck-not-installed" then "shellcheck is not installed"
                                 elif . == "lint-disabled" then "lint disabled (--no-lint)"
                                 else "no linter configured for this language" end) }) )
            + ( if $added == null then
                  [{ metric: "added_lines", language: null, files: ($src | length),
                     reason: "no diff base (use --changed BASE on the working tree)" },
                   { metric: "removed_lines", language: null, files: ($src | length),
                     reason: "no diff base (use --changed BASE on the working tree)" }]
                else [] end )
            | sort_by([.metric, (.language // "")]) ),
          files: ( $src | map(del(.family, .function_length_sum, .lint_reason)) | sort_by(.path) )
        }'
  )" || qq_die "failed to assemble the metric record"

  if [ -n "$out" ]; then
    printf '%s\n' "$json" > "$out" || qq_die "cannot write $out"
  else
    printf '%s\n' "$json"
  fi
  return 0
}

# ── entry point ──────────────────────────────────────────────────────────────
QQ_TMP=""
qq_cleanup() {
  # Only ever a mktemp -d we made ourselves, and only by its full path.
  case "$QQ_TMP" in */chief-quality.*) rm -rf -- "$QQ_TMP" ;; esac
}

qq_main() {
  local cmd="${1:-}"
  case "$cmd" in
    ""|-h|--help|help) qq_usage; return 0 ;;
    measure)           shift ;;
    *)                 qq_die "unknown subcommand: $cmd (try: measure)" ;;
  esac
  QQ_TMP="$(mktemp -d "${TMPDIR:-/tmp}/chief-quality.XXXXXX")" || qq_die "cannot create a temp dir"
  trap qq_cleanup EXIT INT TERM
  qq_write_awk
  qq_measure "$@"
}

qq_main "$@"
