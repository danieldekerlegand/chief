#!/usr/bin/env bash
# test/provider.sh — provider/model flags reach the scheduler without starting an agent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
export GIT_AUTHOR_NAME=provider GIT_AUTHOR_EMAIL=provider@test
export GIT_COMMITTER_NAME=provider GIT_COMMITTER_EMAIL=provider@test
fail() { echo "PROVIDER FAIL: $*" >&2; exit 1; }

CHIEF="$ROOT/bin/chief"

REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null
rm -f tasks/chief/example.json
cat > tasks/chief/provider.json <<'JSON'
{"project":"provider","branchName":"chief/provider","description":"provider flags","iters":1,"dependsOn":[],"touches":[],"warmup":[],"userStories":[]}
JSON
printf 'CHIEF_PROVIDER=devin\nCHIEF_MODEL=devin-default\n' >> .chief/config
git add -A && git commit -q -m config

out="$($CHIEF run -n --provider opencode --model opencode/test provider 2>&1)"
case "$out" in *"provider=opencode"*) ;; *) echo "$out" >&2; fail "provider flag was not propagated" ;; esac
case "$out" in *"model=opencode/test"*) ;; *) echo "$out" >&2; fail "model flag was not propagated" ;; esac

out="$($CHIEF run -n provider 2>&1)"
case "$out" in *"provider=devin"*) ;; *) echo "$out" >&2; fail "config provider was not loaded" ;; esac
case "$out" in *"model=devin-default"*) ;; *) echo "$out" >&2; fail "config model was not loaded" ;; esac

# Exercise the provider command builders directly with offline test doubles.
run_agent() {
  local provider="$1" expected="$2"; local repo="$WORK/$provider"
  mkdir -p "$repo/.chief/state"; git -C "$repo" init -q -b main 2>/dev/null || git -C "$repo" init -q
  git -C "$repo" commit -q --allow-empty -m init
  cat > "$repo/.chief/state/prd.json" <<'JSON'
{"branchName":"chief/provider","userStories":[{"id":"US-1","passes":false}]}
JSON
  printf '%s\n' '# provider test instructions' > "$repo/instructions.md"
  printf '%s\n' '# Chief Progress Log' > "$repo/.chief/state/progress.txt"
  PROVIDER_LOG="$WORK/$provider.args" CHIEF_PROVIDER="$provider" CHIEF_MODEL=test-model \
    CHIEF_PROJECT="$repo" CHIEF_HOME="$ROOT/engine" CHIEF_STATE_DIR=.chief/state \
    PATH="$WORK/fakebin:$PATH" "$ROOT/engine/agent.sh" 1 >/dev/null 2>&1 || fail "$provider agent failed"
  case "$(cat "$WORK/$provider.args")" in *"$expected"*) ;; *) fail "$provider did not receive expected arguments" ;; esac
}
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/devin" <<'SH'
#!/usr/bin/env bash
cat >/dev/null; printf '%s\n' "$*" > "$PROVIDER_LOG"
jq '(.userStories[0].passes)=true' .chief/state/prd.json > .chief/state/prd.tmp && mv .chief/state/prd.tmp .chief/state/prd.json
git add .chief/state/prd.json && git commit -q -m provider-test
echo '<promise>COMPLETE</promise>'
SH
cat > "$WORK/fakebin/opencode" <<'SH'
#!/usr/bin/env bash
cat >/dev/null; printf '%s\n' "$*" > "$PROVIDER_LOG"
jq '(.userStories[0].passes)=true' .chief/state/prd.json > .chief/state/prd.tmp && mv .chief/state/prd.tmp .chief/state/prd.json
git add .chief/state/prd.json && git commit -q -m provider-test
echo '<promise>COMPLETE</promise>'
SH
chmod +x "$WORK/fakebin/devin" "$WORK/fakebin/opencode"
# devin's --print reads the prompt from --prompt-file, NOT stdin; assert it's passed
# (without it devin panics "print mode requires a prompt" and every iteration stalls).
run_agent devin '--permission-mode bypass --respect-workspace-trust false --print --model test-model --prompt-file'
run_agent opencode 'run --model test-model'

echo "PROVIDER PASS — CLI, config, and provider command selection"
