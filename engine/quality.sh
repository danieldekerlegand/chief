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

# Resolved BEFORE anything cd's: the ratchet re-invokes this file as a child
# process for each measurement. A fresh process per measure is not laziness — it
# is what keeps two measurements from sharing one temp dir and one cwd, so the
# base side and the branch side are provably computed by identical, uncontaminated
# code paths.
QQ_SELF="${BASH_SOURCE[0]:-$0}"
case "$QQ_SELF" in /*) ;; *) QQ_SELF="$PWD/$QQ_SELF" ;; esac
qq_self() { bash "$QQ_SELF" "$@"; }

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
  chief quality measure [options] [FILE...]   # emit a metric record
  chief quality ratchet [options]             # BLOCK a merge that regressed one
                                              # (`ratchet --help` for its options)

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
the ratchet that CONSUMES this record is what blocks (see docs/reference/verify-hook.md).
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
  ni = 0; maxind = 0; sawbrace = 0; prevcode = 0; hd = ""; insq = 0
  split("if for while switch catch do else return try with func function new delete typeof await yield case default", KWL, " ")
  for (i in KWL) KW[KWL[i]] = 1
}

{
  raw = $0

  # ── heredoc bodies are DATA, not structure ─────────────────────────────────
  # A shell heredoc carries an awk program, a JSON template, another script —
  # text whose braces and `if`/`for` tokens are not this file's control flow.
  # Reading them as shell is not a rounding error: it inflates nesting without
  # bound (no matching `fi`/`done` ever arrives) and swallows every function
  # boundary after the first heredoc. So the body still counts as source and
  # still feeds duplication (a copy-pasted template IS a copy), but contributes
  # nothing to nesting or function extraction.
  # The same is true of a program passed as a multi-line '...' argument — the
  # `if`/`else` inside an embedded awk or jq program is that program's control
  # flow, not this script's. Single quotes cannot nest or be escaped in shell, so
  # the state is exact: the next quote closes it.
  if (fam == "shell" && insq == 1) {
    if (index(raw, "\047") > 0) insq = 0
    t = trim(raw)
    if (t != "") {
      sloc++
      norm = t; gsub(/[ \t]+/, " ", norm)
      if (length(norm) >= 4 && norm ~ /[A-Za-z0-9_]/) printf "L\t%d\t%s\n", NR, norm
      prevcode = NR
    }
    next
  }

  if (fam == "shell" && hd != "") {
    t = trim(raw)
    if (t == hd) { hd = ""; next }            # the terminator is punctuation
    if (t != "") {
      sloc++
      norm = trim(raw); gsub(/[ \t]+/, " ", norm)
      if (length(norm) >= 4 && norm ~ /[A-Za-z0-9_]/) printf "L\t%d\t%s\n", NR, norm
      prevcode = NR
    }
    next
  }

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
  } else if (code ~ /^[ \t]*#/ || (fam == "none" && code ~ /^[ \t]*(--|\/\/)/)) {
    # `#` is the comment in shell and python. `--` and `//` are NOT — a line of
    # `--argjson foo "$bar" \` is an argument list, and dropping it as a comment
    # both undercounts source and hides the trailing quote that opens a
    # multi-line program argument. They stay comment markers only for the
    # analyzer-less family, where sql/lua/haskell live.
    code = ""
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

  # A quote still standing once balanced pairs have collapsed OPENS a multi-line
  # argument — an embedded awk or jq program. Everything after it on this line is
  # that program's text: truncate before the structural scan (its `{` has its
  # closing `}` inside the string, and counting one without the other pins the
  # nesting depth up forever) and hand the following lines to the body branch.
  if (fam == "shell") {
    p = index(st, "\047")
    if (p > 0) { st = substr(st, 1, p - 1); insq = 1 }
  }

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

  # ── does THIS line open a heredoc? (the body starts on the next one) ───────
  # Matched on the comment-stripped line, and `<<<` (a here-STRING) and `$((1 <<
  # 3))` (a shift) are both excluded — only `<<[-] TAG` with an identifier tag.
  if (fam == "shell") {
    hs = code; sub(/[ \t]#.*$/, "", hs)
    while (match(hs, /<<-?[ \t]*("[A-Za-z_][A-Za-z0-9_]*"|\047[A-Za-z_][A-Za-z0-9_]*\047|[A-Za-z_][A-Za-z0-9_]*)/)) {
      pre = (RSTART > 1) ? substr(hs, RSTART - 1, 1) : ""
      tag = substr(hs, RSTART, RLENGTH)
      hs = substr(hs, RSTART + RLENGTH)
      if (pre == "<") continue                 # `<<<WORD` is a here-STRING
      sub(/^<<-?[ \t]*/, "", tag); gsub(/["\047]/, "", tag)
      if (tag != "") { hd = tag; break }
    }
  }
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

# ── the ratchet ──────────────────────────────────────────────────────────────
#
# `measure` answers "what is this file set like". The RATCHET answers the only
# question a merge gate cares about: "did this branch make it worse?" It is a
# monotone gate — metrics may hold or improve freely, and may not regress past a
# configured tolerance. Nothing here consults a model either; every verdict is
# arithmetic over two records produced by the same code.
#
# TWO AXES, both deterministic, both optional to fail independently:
#
#   SCOPE   the changed files, measured on HEAD and again at BASE. A repo with
#           pre-existing 8-deep nesting is NOT blocked for its history — only for
#           what this branch adds to the files it touched. This mirrors the
#           path-scoped, diff-driven shape of `.chief/verify.sh` and always runs.
#
#   BASELINE  the whole tracked tree, measured on HEAD and compared against a
#           COMMITTED record (`.chief/quality-baseline.json`). This is the talos
#           ratchet: a floor that may be lowered but not raised. It is what catches
#           an all-new-files branch, which the scope axis has no before-state for.
#           It runs only when the baseline file exists, so `chief init` in a
#           brownfield repo is never unmergeable on day one. `--write-baseline` is
#           the explicit, reviewable re-baseline: it rewrites a committed file, so
#           the loosening shows up in the diff like any other change.
#
# UNMEASURED IS NOT ZERO — the discipline `measure` establishes carries through
# here. A metric that is unmeasured on either side, or whose unmeasured LANGUAGE
# SET differs between the sides, is SKIPPED and printed as skipped. It is never
# read as "held steady", because a vanished metric that scores as no-regression is
# exactly the blind spot this gate exists to close.

# Tracked metrics, in report order. Every one is LOWER-IS-BETTER, so a regression
# is always "branch > base + tolerance" and there is no per-metric direction table
# to get backwards.
QUALITY_METRICS_DEFAULT="duplicate_blocks duplicate_line_pct max_nesting_depth \
function_length_max function_length_mean single_use_functions lint_violations"

# Every metric the ratchet knows how to compare (a superset of the default set —
# a repo may track more). Tracking a name outside this list is an error, not a
# metric that silently never fires.
QUALITY_METRICS_KNOWN="source_lines files functions duplicate_blocks duplicate_lines \
duplicate_line_pct max_nesting_depth function_length_max function_length_mean \
single_use_functions lint_violations"

# Default tolerances: how much WORSE a branch may be, in the metric's own units.
# Zero where any regression is a real defect (a duplicated block, a new lint
# violation); non-zero where honest new work legitimately moves the number.
qq_default_tolerances() {
  : "${CHIEF_QUALITY_TOL_duplicate_blocks:=0}"
  : "${CHIEF_QUALITY_TOL_duplicate_line_pct:=1}"
  : "${CHIEF_QUALITY_TOL_max_nesting_depth:=1}"
  : "${CHIEF_QUALITY_TOL_function_length_max:=15}"
  : "${CHIEF_QUALITY_TOL_function_length_mean:=5}"
  : "${CHIEF_QUALITY_TOL_single_use_functions:=2}"
  : "${CHIEF_QUALITY_TOL_lint_violations:=0}"
  : "${CHIEF_QUALITY_TOL_source_lines:=99999}"
  : "${CHIEF_QUALITY_TOL_files:=99999}"
  : "${CHIEF_QUALITY_TOL_functions:=99999}"
  : "${CHIEF_QUALITY_TOL_duplicate_lines:=0}"
}

qq_tol() { local n="CHIEF_QUALITY_TOL_$1"; echo "${!n-0}"; }

# The per-file column that EXPLAINS a total, so a blocking message can name the
# files that moved it. Not every total decomposes exactly (a mean does not), so
# this names the closest per-file signal rather than pretending to be exact.
qq_field_for() {
  case "$1" in
    duplicate_blocks|duplicate_lines|duplicate_line_pct) echo "duplicate_lines" ;;
    max_nesting_depth)                                   echo "max_nesting_depth" ;;
    function_length_max|function_length_mean)            echo "function_length_max" ;;
    single_use_functions|functions|files)                echo "functions" ;;
    lint_violations)                                     echo "lint_violations" ;;
    *)                                                   echo "source_lines" ;;
  esac
}

# Per-repo configuration. `.chief/quality.conf` (a sibling of `.chief/config`)
# wins over `.chief/config`, and the ENVIRONMENT wins over both — so a one-off
# `CHIEF_QUALITY_TOL_x=3 chief quality ratchet` never has to edit a tracked file,
# while the durable setting lives in a file whose diff a reviewer can see. There
# is deliberately no way to disable a metric implicitly: dropping it from
# CHIEF_QUALITY_METRICS is a visible edit to a committed config.
qq_load_config() {
  local f dump line name probe
  for f in "${CHIEF_QUALITY_CONFIG:-.chief/quality.conf}" ".chief/config"; do
    [ -f "$f" ] || continue
    # Sourced in a SUBSHELL and harvested by name: reading a config must never be
    # able to move CHIEF_BASE_BRANCH or any other engine variable out from under us.
    dump="$( ( set +u; . "./$f" >/dev/null 2>&1; set ) 2>/dev/null \
             | LC_ALL=C grep '^CHIEF_QUALITY_[A-Za-z0-9_]*=' )" || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      name="${line%%=*}"
      eval "probe=\${$name-__qq_unset__}"
      [ "$probe" = "__qq_unset__" ] || continue   # already set: env, or an earlier file
      eval "$line"
    done <<EOF
$dump
EOF
  done
}

qq_ratchet_usage() {
  cat <<EOF
chief quality ratchet — block a merge that makes the codebase measurably worse.

Usage:
  chief quality ratchet [options]
  chief quality ratchet --write-baseline [options]

Options:
  --base REV           base revision (default: \$CHIEF_BASE_BRANCH, else main)
  --baseline FILE      committed baseline record (default $QUALITY_BASELINE_DEFAULT)
  --write-baseline     (re)write the baseline from the working tree and exit 0.
                       The explicit, reviewable escape hatch — commit the result.
  --no-baseline        evaluate the scope axis only
  --root DIR           repo root (default: git toplevel)
  --window N           duplication block size (default $QUALITY_DUP_WINDOW)
  --no-lint            skip the lint family on both sides
  -q, --quiet          suppress progress notes on stderr
  -h, --help           this message

Config: $QUALITY_BASELINE_CONF (preferred) or .chief/config; env wins over both.
  CHIEF_QUALITY_METRICS="$QUALITY_METRICS_DEFAULT"
  CHIEF_QUALITY_TOL_<metric>=<number>     how much worse the branch may be
  CHIEF_QUALITY_DUP_WINDOW=$QUALITY_DUP_WINDOW
  CHIEF_VERIFY_QUALITY=0                  skip this gate entirely (like CHIEF_VERIFY_TESTS=0)

Exit: 0 = allow the merge, 1 = BLOCK (a tracked metric regressed), 2 = usage or
environment error. NO_VERIFY=1 bypasses the whole verify hook upstream of this.
EOF
}

# qq_cmp BASE_JSON BRANCH_JSON TRACKED_JSON -> TSV: status metric base branch delta tol note
qq_cmp() {
  jq -rn --slurpfile b "$1" --slurpfile h "$2" --argjson tracked "$3" '
    def uset($r; $m): [ $r.unmeasured[]? | select(.metric == $m)
                        | ((.language // "-") + "|" + (.reason // "")) ] | sort;
    def why($u): ( $u | map(split("|")[1]) | map(select(. != "")) | unique ) as $r
                 | if ($r | length) == 0 then "not measured on either side"
                   else "not measured — " + ($r | join("; ")) end;
    def num: if . == null then "n/a"
             elif (. | floor) == . then (. | floor | tostring)
             else (. | tostring) end;
    def signed: if . == null then "n/a" elif . > 0 then "+" + (. | num) else (. | num) end;
    $b[0] as $B | $h[0] as $H
    | $tracked[]
    | .metric as $m | .tol as $tol
    | ($B.totals[$m]) as $bv | ($H.totals[$m]) as $hv
    | (uset($B; $m)) as $bu | (uset($H; $m)) as $hu
    | if ($B.scope.source_files // 0) == 0 then
        ["SKIP", $m, "n/a", ($hv|num), "n/a", ($tol|num),
         "no file in scope exists at the base — nothing to compare against"]
      elif $bv == null and $hv == null then
        ["SKIP", $m, "n/a", "n/a", "n/a", ($tol|num), why($bu + $hu)]
      elif $bv == null or $hv == null then
        ["SKIP", $m, ($bv|num), ($hv|num), "n/a", ($tol|num),
         "measured on one side only — not comparable"]
      elif $bu != $hu then
        ["SKIP", $m, ($bv|num), ($hv|num), "n/a", ($tol|num),
         "the unmeasured language set differs between the two sides — not comparable"]
      else
        ((($hv - $bv) * 100 | round) / 100) as $d
        | [ (if $d > $tol then "BLOCK" else "OK" end),
            $m, ($bv|num), ($hv|num), ($d|signed), ($tol|num), "" ]
      end
    | @tsv' 2>/dev/null
}

# qq_contrib BASE_JSON BRANCH_JSON FIELD -> up to 3 TSV rows: path base branch delta
qq_contrib() {
  jq -rn --slurpfile b "$1" --slurpfile h "$2" --arg f "$3" '
    (($b[0].files // []) | map({key: .path, value: .}) | from_entries) as $bm
    | ($h[0].files // [])
    | map( . as $x
           | ((($bm[$x.path] // {})[$f]) // 0) as $bv
           | (($x[$f]) // 0) as $hv
           | { path: $x.path, b: $bv, h: $hv, d: ($hv - $bv) } )
    | map(select(.d > 0)) | sort_by([(-.d), .path]) | .[0:3]
    | .[] | [.path, (.b|tostring), (.h|tostring), (.d|tostring)] | @tsv' 2>/dev/null
}

# Print one axis's verdict table; returns 1 if anything in it BLOCKs.
qq_report() {
  local title="$1" basef="$2" branchf="$3" rows="$4" bad=0
  local st m bv hv dl tol note field line
  echo "quality: $title"
  while IFS="$(printf '\t')" read -r st m bv hv dl tol note; do
    [ -n "$st" ] || continue
    case "$st" in
      OK)    printf 'quality:   ok     %-22s %8s -> %-8s (delta %-6s tol %s)\n' "$m" "$bv" "$hv" "$dl" "$tol" ;;
      SKIP)  printf 'quality:   skip   %-22s %s\n' "$m" "$note" ;;
      BLOCK)
        bad=1
        printf 'quality:   BLOCK  %-22s base %s -> branch %s (delta %s, tolerance %s)\n' \
          "$m" "$bv" "$hv" "$dl" "$tol"
        field="$(qq_field_for "$m")"
        line="$(qq_contrib "$basef" "$branchf" "$field")"
        if [ -n "$line" ]; then
          printf 'quality:            top contributors by %s (base -> branch):\n' "$field"
          while IFS="$(printf '\t')" read -r p a c d; do
            [ -n "$p" ] || continue
            printf 'quality:              %-46s %s -> %s (+%s)\n' "$p" "$a" "$c" "$d"
          done <<EOF
$line
EOF
        fi ;;
    esac
  done <<EOF
$rows
EOF
  return $bad
}

QUALITY_BASELINE_DEFAULT=".chief/quality-baseline.json"
QUALITY_BASELINE_CONF=".chief/quality.conf"

qq_ratchet() {
  local root="" base="" baseline="" write=0 use_baseline=1 do_lint=1 lintarg=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --base)            [ $# -ge 2 ] || qq_die "--base needs a revision"; base="$2";     shift 2 ;;
      --baseline)        [ $# -ge 2 ] || qq_die "--baseline needs a file"; baseline="$2"; shift 2 ;;
      --root)            [ $# -ge 2 ] || qq_die "--root needs a directory"; root="$2";    shift 2 ;;
      --window)          [ $# -ge 2 ] || qq_die "--window needs a number";
                         CHIEF_QUALITY_DUP_WINDOW="$2"; QUALITY_DUP_WINDOW="$2";          shift 2 ;;
      --write-baseline)  write=1; shift ;;
      --no-baseline)     use_baseline=0; shift ;;
      --no-lint)         do_lint=0; lintarg="--no-lint"; shift ;;
      -q|--quiet)        QQ_QUIET=1; shift ;;
      -h|--help)         qq_ratchet_usage; return 0 ;;
      *)                 qq_die "unknown option: $1 (try: chief quality ratchet --help)" ;;
    esac
  done

  command -v jq  >/dev/null 2>&1 || qq_die "jq is required"
  command -v git >/dev/null 2>&1 || qq_die "git is required"

  [ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  [ -d "$root" ] || qq_die "not a directory: $root"
  cd "$root" || qq_die "cannot cd to $root"

  qq_load_config
  qq_default_tolerances
  QUALITY_DUP_WINDOW="${CHIEF_QUALITY_DUP_WINDOW:-$QUALITY_DUP_WINDOW}"
  export CHIEF_QUALITY_DUP_WINDOW="$QUALITY_DUP_WINDOW"
  export CHIEF_QUALITY_SHELLCHECK_SEVERITY="${CHIEF_QUALITY_SHELLCHECK_SEVERITY:-$QUALITY_SHELLCHECK_SEVERITY}"

  # The documented skip, spelled exactly like the behavioral-test skip the verify
  # hook already has. Iterating locally must not be punished.
  if [ "${CHIEF_VERIFY_QUALITY:-1}" != "1" ]; then
    echo "quality: ratchet skipped (CHIEF_VERIFY_QUALITY=${CHIEF_VERIFY_QUALITY:-1})"
    return 0
  fi

  [ -n "$baseline" ] || baseline="${CHIEF_QUALITY_BASELINE:-$QUALITY_BASELINE_DEFAULT}"
  [ -n "$base" ]     || base="${CHIEF_BASE_BRANCH:-main}"

  # ── the tracked set, validated ─────────────────────────────────────────────
  local metrics tracked="[" first=1 m t
  metrics="${CHIEF_QUALITY_METRICS:-$QUALITY_METRICS_DEFAULT}"
  for m in $metrics; do
    case "$m" in *[!a-z_]*) qq_die "not a metric name: $m" ;; esac
    case " $QUALITY_METRICS_KNOWN " in
      *" $m "*) ;;
      *) qq_die "unknown metric '$m' (known: $QUALITY_METRICS_KNOWN)" ;;
    esac
    t="$(qq_tol "$m")"
    case "$t" in ''|*[!0-9.]*) qq_die "tolerance for $m is not a number: '$t'" ;; esac
    [ "$first" = 1 ] || tracked="$tracked,"
    first=0
    tracked="$tracked{\"metric\":\"$m\",\"tol\":$t}"
  done
  [ "$first" = 0 ] || qq_die "CHIEF_QUALITY_METRICS is empty — nothing to ratchet"
  tracked="$tracked]"

  local tmp="$QQ_TMP/ratchet"
  mkdir -p "$tmp" || qq_die "cannot create $tmp"

  # ── --write-baseline: measure the whole tracked tree and stop ──────────────
  local treelist="$tmp/tree.txt"
  git ls-files -- . > "$treelist" 2>/dev/null || qq_die "git ls-files failed"

  if [ "$write" = "1" ]; then
    mkdir -p "$(dirname "$baseline")" 2>/dev/null
    qq_self measure -q $lintarg --root "$root" --window "$QUALITY_DUP_WINDOW" \
      --files-from "$treelist" -o "$baseline" || qq_die "could not measure the tree"
    echo "quality: wrote baseline $baseline — review and COMMIT it (it is the ratchet floor)"
    return 0
  fi

  # ── axis 1: the changed-file scope, HEAD vs BASE ───────────────────────────
  git rev-parse --verify --quiet "$base" >/dev/null 2>&1 \
    || qq_die "not a revision: $base (set CHIEF_BASE_BRANCH or pass --base)"

  local changed="$tmp/changed.txt" scope="$tmp/scope.txt" fresh=0 f
  git diff --name-only "$base"...HEAD > "$changed" 2>/dev/null \
    || qq_die "git diff against $base failed"
  if [ ! -s "$changed" ]; then
    echo "quality: no diff vs $base — nothing to ratchet (allowing)"
    return 0
  fi

  # The scope axis is a DELTA, so it is honest only over files that exist on both
  # sides. A file this branch created has no before-state; measuring it against a
  # nonexistent base would score every new file's first function as a regression
  # from zero. New files are counted, announced, and handed to the baseline axis,
  # which is whole-tree and does have a floor to compare them against.
  : > "$scope"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue                       # deleted on the branch
    if git cat-file -e "$base:$f" 2>/dev/null; then
      printf '%s\n' "$f" >> "$scope"
    else
      fresh=$((fresh + 1))
    fi
  done < "$changed"

  local rc=0 rows note=""
  [ "$fresh" = 0 ] || note=" ($fresh file(s) new on this branch — no base version, deferred to the baseline axis)"

  if [ ! -s "$scope" ]; then
    echo "quality: scope — no changed file has a version at $base$note"
  else
    qq_note "ratchet — measuring $(wc -l < "$scope" | tr -d ' ') changed path(s) on HEAD and at $base"
    local sbase="$tmp/scope.base.json" shead="$tmp/scope.head.json"
    qq_self measure -q $lintarg --root "$root" --window "$QUALITY_DUP_WINDOW" \
      --files-from "$scope" -o "$shead" || qq_die "could not measure the branch"
    qq_self measure -q $lintarg --root "$root" --window "$QUALITY_DUP_WINDOW" \
      --files-from "$scope" --rev "$base" -o "$sbase" || qq_die "could not measure $base"

    rows="$(qq_cmp "$sbase" "$shead" "$tracked")"
    qq_report "scope — the $(jq -r '.scope.source_files' "$shead") changed source file(s), HEAD vs $base$note" \
      "$sbase" "$shead" "$rows" || rc=1
  fi

  # ── axis 2: the committed baseline, whole tree ─────────────────────────────
  if [ "$use_baseline" = "0" ]; then
    :
  elif [ ! -f "$baseline" ]; then
    echo "quality: no baseline at $baseline — whole-tree ratchet inactive"
    echo "quality:   (create it once with: chief quality ratchet --write-baseline, then commit it)"
  elif ! jq -e '.schema == "'"$QUALITY_SCHEMA"'"' "$baseline" >/dev/null 2>&1; then
    echo "quality:   skip   baseline $baseline is not a $QUALITY_SCHEMA record — rewrite it with --write-baseline"
  else
    local thead="$tmp/tree.head.json"
    qq_self measure -q $lintarg --root "$root" --window "$QUALITY_DUP_WINDOW" \
      --files-from "$treelist" -o "$thead" || qq_die "could not measure the tree"
    # A baseline computed with a different duplication window, or on a host where
    # the linter was absent, is NOT comparable — say so instead of comparing.
    local mism
    mism="$(jq -rn --slurpfile a "$baseline" --slurpfile b "$thead" '
      [ if $a[0].config.dup_window != $b[0].config.dup_window
          then "dup_window \($a[0].config.dup_window) vs \($b[0].config.dup_window)" else empty end,
        if $a[0].config.lint_tool != $b[0].config.lint_tool
          then "lint_tool \($a[0].config.lint_tool) vs \($b[0].config.lint_tool)" else empty end ]
      | join(", ")')"
    if [ -n "$mism" ]; then
      echo "quality:   skip   baseline is not comparable to this run ($mism) — re-run --write-baseline"
    else
      rows="$(qq_cmp "$baseline" "$thead" "$tracked")"
      qq_report "baseline — the whole tracked tree vs $baseline" "$baseline" "$thead" "$rows" || rc=1
    fi
  fi

  if [ "$rc" != "0" ]; then
    echo "quality: BLOCKED — a tracked metric regressed past its tolerance."
    echo "quality:   Fix the named files, loosen the tolerance in $QUALITY_BASELINE_CONF (a"
    echo "quality:   reviewable diff), or re-baseline deliberately with --write-baseline."
    return 1
  fi
  echo "quality: OK — no tracked metric regressed (allowing)"
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
    measure|ratchet)   shift ;;
    *)                 qq_die "unknown subcommand: $cmd (try: measure | ratchet)" ;;
  esac
  QQ_TMP="$(mktemp -d "${TMPDIR:-/tmp}/chief-quality.XXXXXX")" || qq_die "cannot create a temp dir"
  trap qq_cleanup EXIT INT TERM
  qq_write_awk
  if [ "$cmd" = "ratchet" ]; then qq_ratchet "$@"; else qq_measure "$@"; fi
}

qq_main "$@"
