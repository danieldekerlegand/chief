#!/usr/bin/env bash
# test/usage.sh — `chief help` must PRINT its usage, not EXECUTE it.
#
# The failure this pins (hit in production): usage() opened its heredoc with an
# UNQUOTED delimiter — `cat <<EOF` rather than `cat <<'EOF'` — so the shell expanded
# the whole 150-line usage block before printing it. The usage text is written in a
# markdown-ish style with backticks around command names, and in shell a backtick pair
# is COMMAND SUBSTITUTION. Nine pairs were being executed on every `chief help`:
#
#   `measure` `ratchet` `--write-baseline`   → "command not found" noise
#   `chief run` `chief ps` `chief monitor`   → REAL commands, actually invoked
#
# and an unescaped $CHIEF_BASE_BRANCH aborted the function under `set -u` before most
# of them were reached. Two consequences, both observed:
#
#   1. Exit codes inverted. `chief help` exited 1 (help is not an error) and an
#      unknown command exited 0 (the set -u abort killed the function before its
#      `exit 2`), so a typo'd chief invocation reported SUCCESS to a CI script.
#   2. With CHIEF_BASE_BRANCH set in the environment, execution got past the abort
#      and `chief help` spawned `chief monitor` — a live-refresh loop that never
#      returns. `chief help` hung, leaving an orphaned monitor behind.
#
# Rule: the usage heredoc expands EXACTLY three variables ($VERSION, $CHIEF_RUNS,
# $SELF) and executes nothing. Everything else in it is literal text.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "USAGE FAIL: $*" >&2; exit 1; }

# Sandbox HOME so the help path can't touch the real host registry.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# ── 1. Static: nothing unintended is expandable inside the heredoc ────────────
# Locate usage()'s heredoc body so the scan can't drift if the block moves.
body="$(awk '
  /^usage\(\)/        { infn=1 }
  infn && /cat <<EOF/ { inbody=1; next }
  inbody && /^EOF$/   { exit }
  inbody              { print }
' bin/chief)"
[ -n "$body" ] || fail "could not locate the usage() heredoc body in bin/chief"

# Unescaped backtick = command substitution. Every backtick in the text must be \`.
if bad="$(printf '%s\n' "$body" | grep -n '\(^\|[^\\]\)`' || true)"; [ -n "$bad" ]; then
  fail "unescaped backtick in the usage heredoc — the shell will EXECUTE it:
$bad"
fi

# Only these three expansions are intentional; any other $VAR is a latent set -u abort.
if bad="$(printf '%s\n' "$body" \
          | grep -oE '(^|[^\\])\$\{?[A-Za-z_][A-Za-z_0-9]*' \
          | grep -oE '[A-Za-z_][A-Za-z_0-9]*$' \
          | grep -vxE 'VERSION|CHIEF_RUNS|SELF' | sort -u || true)"; [ -n "$bad" ]; then
  fail "unescaped \$variable in the usage heredoc (escape it as \\\$NAME): $(echo "$bad" | tr "\n" " ")"
fi

# ── 2. Behavioral: help prints clean and exits 0 ──────────────────────────────
rc=0; out="$(HOME="$SANDBOX" bash bin/chief help 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "'chief help' exited $rc — help is not an error"
case "$out" in
  *"command not found"*) fail "'chief help' executed something: $(printf '%s\n' "$out" | grep 'command not found' | head -3)" ;;
  *"unbound variable"*)  fail "'chief help' hit an unbound variable under set -u" ;;
esac
# The intentional three still expand.
case "$out" in *'$VERSION'*|*'$CHIEF_RUNS'*|*'$SELF'*) fail "an intentional expansion is now over-escaped" ;; esac
printf '%s\n' "$out" | grep -q '`chief monitor`' \
  || fail "the literal text \`chief monitor\` is missing from the usage output"

# ── 3. The hang case: a set CHIEF_BASE_BRANCH must change nothing ─────────────
rc=0; out2="$(HOME="$SANDBOX" CHIEF_BASE_BRANCH=main bash bin/chief help 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "'chief help' exited $rc with CHIEF_BASE_BRANCH set"
[ "$out" = "$out2" ] || fail "usage output changes when CHIEF_BASE_BRANCH is set — it is still being expanded"

# ── 4. An unknown command is an ERROR, and says so in its exit code ───────────
set +e
HOME="$SANDBOX" bash bin/chief florble >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unknown command exited $rc, want 2 (0 would let a typo pass CI)"

echo "USAGE PASS — help prints (exit 0), executes nothing, and an unknown command exits 2"
