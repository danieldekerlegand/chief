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
scratch_repo() {                 # a minimal project agent.sh can complete in one iteration
  local repo="$1"
  mkdir -p "$repo/.chief/state"; git -C "$repo" init -q -b main 2>/dev/null || git -C "$repo" init -q
  git -C "$repo" commit -q --allow-empty -m init
  cat > "$repo/.chief/state/prd.json" <<'JSON'
{"branchName":"chief/provider","userStories":[{"id":"US-1","passes":false}]}
JSON
  printf '%s\n' '# provider test instructions' > "$repo/instructions.md"
  printf '%s\n' '# Chief Progress Log' > "$repo/.chief/state/progress.txt"
}
run_agent() {
  local provider="$1" expected="$2"; local repo="$WORK/$provider"
  scratch_repo "$repo"
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
# The opencode double records its ARGS *and* the backend env the caller published —
# the `local` preset's whole job is exporting an endpoint into this process.
cat > "$WORK/fakebin/opencode" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
{ printf '%s\n' "$*"; env | grep -E '^(OPENAI_BASE_URL|OPENAI_API_KEY|LOCAL_BASE_URL)=' | sort || true; } > "$PROVIDER_LOG"
jq '(.userStories[0].passes)=true' .chief/state/prd.json > .chief/state/prd.tmp && mv .chief/state/prd.tmp .chief/state/prd.json
git add .chief/state/prd.json && git commit -q -m provider-test
echo '<promise>COMPLETE</promise>'
SH
# A tripwire, not a double: nothing in this test may ever reach the PAID default
# provider. It shadows any real `claude` on PATH so a preset that silently degraded
# would leave evidence here instead of spending money.
cat > "$WORK/fakebin/claude" <<'SH'
#!/usr/bin/env bash
cat >/dev/null; printf '%s\n' "$*" > "$WORK_PAID_TRIPWIRE"
echo 'paid provider dispatched' >&2
exit 1
SH
chmod +x "$WORK/fakebin/devin" "$WORK/fakebin/opencode" "$WORK/fakebin/claude"
export WORK_PAID_TRIPWIRE="$WORK/paid-dispatch"
# devin's --print reads the prompt from --prompt-file, NOT stdin; assert it's passed
# (without it devin panics "print mode requires a prompt" and every iteration stalls).
run_agent devin '--permission-mode bypass --respect-workspace-trust false --print --model test-model --prompt-file'
run_agent opencode 'run --model test-model'

# ── PRESET `local` (engine/preset.sh) — cost-avoidance mode, resolved offline ──
# The preset is a bundle over the SAME opencode builder asserted above, so these
# cases prove resolution only: no server is contacted and no model is loaded.
# Every invocation is env -u'd because this suite may itself run inside a chief
# worktree, whose driver exports CHIEF_PROVIDER/CHIEF_MODEL into the environment —
# inheriting those would read as a preset·provider conflict.
preset_env() { env -u CHIEF_PROVIDER -u CHIEF_TOOL -u CHIEF_MODEL -u CHIEF_PRESET \
  -u CHIEF_LOCAL_ENDPOINT -u CHIEF_LOCAL_MODEL -u CHIEF_LOCAL_ENDPOINT_ENV \
  -u CHIEF_LOCAL_API_KEY -u CHIEF_LOCAL_API_KEY_ENV \
  -u OPENAI_BASE_URL -u OPENAI_API_KEY -u LOCAL_BASE_URL "$@"; }

# 1. Resolution reaches the opencode command builder with the CONFIGURED model, and
#    publishes the configured endpoint into the provider's environment.
repo="$WORK/preset-local"; scratch_repo "$repo"
preset_env PROVIDER_LOG="$WORK/preset-local.args" \
  CHIEF_PRESET=local CHIEF_LOCAL_ENDPOINT='http://127.0.0.1:11434/v1' CHIEF_LOCAL_MODEL='local/qwen-test' \
  CHIEF_PROJECT="$repo" CHIEF_HOME="$ROOT/engine" CHIEF_STATE_DIR=.chief/state \
  PATH="$WORK/fakebin:$PATH" "$ROOT/engine/agent.sh" 1 >/dev/null 2>&1 \
  || fail "preset local did not complete an iteration through the opencode double"
log="$(cat "$WORK/preset-local.args")"
case "$log" in *"run --model local/qwen-test"*) ;; *) echo "$log" >&2; fail "preset local did not reach the opencode builder with CHIEF_LOCAL_MODEL" ;; esac
case "$log" in *"OPENAI_BASE_URL=http://127.0.0.1:11434/v1"*) ;; *) echo "$log" >&2; fail "preset local did not publish CHIEF_LOCAL_ENDPOINT to the provider" ;; esac
case "$log" in *"OPENAI_API_KEY="?*) ;; *) echo "$log" >&2; fail "preset local left the placeholder credential empty (SDKs reject that)" ;; esac

# 2. The endpoint's env NAME is configurable too — nothing about the local backend
#    is hard-coded, so a non-OpenAI-shaped server needs no engine patch.
repo="$WORK/preset-envname"; scratch_repo "$repo"
preset_env PROVIDER_LOG="$WORK/preset-envname.args" \
  CHIEF_PRESET=local CHIEF_LOCAL_ENDPOINT='http://10.0.0.9:8080/v1' CHIEF_LOCAL_MODEL='local/mistral-test' \
  CHIEF_LOCAL_ENDPOINT_ENV=LOCAL_BASE_URL \
  CHIEF_PROJECT="$repo" CHIEF_HOME="$ROOT/engine" CHIEF_STATE_DIR=.chief/state \
  PATH="$WORK/fakebin:$PATH" "$ROOT/engine/agent.sh" 1 >/dev/null 2>&1 \
  || fail "preset local with a custom endpoint env failed"
log="$(cat "$WORK/preset-envname.args")"
case "$log" in *"LOCAL_BASE_URL=http://10.0.0.9:8080/v1"*) ;; *) echo "$log" >&2; fail "CHIEF_LOCAL_ENDPOINT_ENV was not honored" ;; esac

# 3. NEGATIVE — unconfigured, the preset must refuse with the actionable message and
#    must NOT fall through to the paid default provider (the tripwire proves it).
repo="$WORK/preset-unset"; scratch_repo "$repo"
set +e
out="$(preset_env PROVIDER_LOG="$WORK/preset-unset.args" CHIEF_PRESET=local \
  CHIEF_PROJECT="$repo" CHIEF_HOME="$ROOT/engine" CHIEF_STATE_DIR=.chief/state \
  PATH="$WORK/fakebin:$PATH" "$ROOT/engine/agent.sh" 1 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "$out" >&2; fail "unconfigured preset exited 0 instead of refusing"; }
case "$out" in *CHIEF_LOCAL_ENDPOINT*) ;; *) echo "$out" >&2; fail "unconfigured preset did not name CHIEF_LOCAL_ENDPOINT" ;; esac
case "$out" in *CHIEF_LOCAL_MODEL*) ;; *) echo "$out" >&2; fail "unconfigured preset did not name CHIEF_LOCAL_MODEL" ;; esac
[ "$rc" = 1 ] || { echo "$out" >&2; fail "unconfigured preset exited $rc, not agent.sh's documented bad-invocation code 1"; }
# It must refuse AS A PRESET, not limp on and die at the generic provider validation —
# that path means resolution "succeeded" with nothing configured.
case "$out" in *"Invalid provider"*) echo "$out" >&2; fail "unconfigured preset fell through to provider validation instead of refusing" ;; *) ;; esac
[ ! -e "$WORK/paid-dispatch" ] || fail "unconfigured preset dispatched the PAID default provider"

# 4. The same switch at the CLI: it resolves before provider defaulting, so the
#    scheduler (and therefore `chief ps`/`monitor`/events) sees the plain pair —
#    and it wins over the config's CHIEF_PROVIDER=devin default without conflicting.
out="$(preset_env CHIEF_LOCAL_ENDPOINT='http://127.0.0.1:1234/v1' CHIEF_LOCAL_MODEL='local/qwen-test' \
  "$CHIEF" run -n --local provider 2>&1)"
case "$out" in *"provider=opencode"*) ;; *) echo "$out" >&2; fail "--local did not resolve to provider=opencode" ;; esac
case "$out" in *"model=local/qwen-test"*) ;; *) echo "$out" >&2; fail "--local did not resolve to CHIEF_LOCAL_MODEL" ;; esac

set +e
out="$(preset_env "$CHIEF" run -n --local provider 2>&1)"; rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "$out" >&2; fail "unconfigured --local exited 0 instead of refusing"; }
case "$out" in *CHIEF_LOCAL_ENDPOINT*CHIEF_LOCAL_MODEL*) ;; *) echo "$out" >&2; fail "unconfigured --local lacked the actionable message" ;; esac
[ "$rc" = 2 ] || { echo "$out" >&2; fail "unconfigured --local exited $rc, not chief run's documented usage code 2"; }
case "$out" in *"invalid provider"*) echo "$out" >&2; fail "unconfigured --local fell through to provider validation instead of refusing" ;; *) ;; esac
case "$out" in *"provider=devin"*) echo "$out" >&2; fail "unconfigured --local fell back to the configured paid provider" ;; *) ;; esac

if preset_env "$CHIEF" run -n --preset bogus provider >/dev/null 2>&1; then fail "chief run accepted an unknown preset"; fi

# `chief models`: claude prints its stable family aliases; an unknown provider is rejected.
out="$("$CHIEF" models claude 2>&1)"
case "$out" in *opus*sonnet*haiku*fable*) ;; *) echo "$out" >&2; fail "chief models claude missing family aliases" ;; esac
if "$CHIEF" models bogus >/dev/null 2>&1; then fail "chief models accepted an unknown provider"; fi

echo "PROVIDER PASS — CLI, config, provider command selection, and the local preset"
