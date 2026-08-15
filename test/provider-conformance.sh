#!/usr/bin/env bash
# test/provider-conformance.sh — the roster-driven provider conformance harness.
#
# ONE test for EVERY provider the validators accept. It drives the real
# engine/agent.sh against a scripted fake CLI on PATH and asserts, per provider:
#
#   • the EXACT argv the engine composes (with and without --model),
#   • prompt delivery on the documented channel (stdin vs. --prompt-file),
#   • --model propagation where the provider wires it (and its ABSENCE where it
#     doesn't — an "unwired" entry is a recorded decision, not an oversight),
#   • that a fake emitting <promise>COMPLETE</promise> after a commit ends the
#     loop with exit 0.
#
# ── REGISTERING A NEW PROVIDER (the whole job) ───────────────────────────────
# Add ONE line to the ROSTER array below. Nothing else in this file changes —
# the fake CLI is generated from a shared double, so there is no new scaffolding.
# See docs/guides/providers.md ("The checklist", item 10) for the surrounding surfaces.
#
#   name|prompt-channel|model-stance|argv-WITH-model|argv-WITHOUT-model
#
#     prompt-channel  stdin | prompt-file   (the channel the case documents)
#     model-stance    wired | unwired       (unwired ⇒ %MODEL% must NOT appear,
#                                            and `chief run --model` must REFUSE)
#     argv-*          space-separated, EXACT and complete; placeholders
#                     %MODEL% and %PROMPT_FILE% are substituted at assert time.
#                     (One arg per word — an expectation needing an embedded
#                     space would need a different separator here.)
#
# It also carries the ROSTER-DRIFT GUARD: the two independent validator lists
# (engine/agent.sh's $PROVIDER guard and bin/chief cmd_run's case) and this
# ROSTER must name the same set, so they can never silently diverge again.
#
# Hermetic: temp CHIEF_* prefixes, fake CLIs on PATH, no network, never touches
# the developer's ~/.chief. bash 3.2 compatible (no associative arrays).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
export GIT_AUTHOR_NAME=conformance GIT_AUTHOR_EMAIL=conformance@test
export GIT_COMMITTER_NAME=conformance GIT_COMMITTER_EMAIL=conformance@test
fail() { echo "PROVIDER-CONFORMANCE FAIL: $*" >&2; exit 1; }
note() { echo "provider-conformance: $*"; }

CHIEF="$ROOT/bin/chief"

# ── THE ROSTER ───────────────────────────────────────────────────────────────
# amp is `unwired` by record, not by accident: its CLI has no model selector, so
# chief REFUSES an explicit --model for it rather than ignoring it (settled by
# tasklist 85 — docs/guides/providers.md#model-overrides). Section 4 below asserts that
# refusal for every `unwired` entry, so the stance stays a decision, not a drop.
ROSTER=(
"claude|stdin|wired|--dangerously-skip-permissions --print --model %MODEL%|--dangerously-skip-permissions --print"
"devin|prompt-file|wired|--permission-mode bypass --respect-workspace-trust false --print --model %MODEL% --prompt-file %PROMPT_FILE%|--permission-mode bypass --respect-workspace-trust false --print --prompt-file %PROMPT_FILE%"
"opencode|stdin|wired|run --model %MODEL%|run"
"amp|stdin|unwired|--dangerously-allow-all|--dangerously-allow-all"
)

roster_names() { for r in "${ROSTER[@]}"; do printf '%s\n' "${r%%|*}"; done | sort -u; }

# ── 1) ROSTER-DRIFT GUARD ────────────────────────────────────────────────────
# The two validator lists are hand-maintained, in different files, in different
# syntaxes. Parse both and compare them to each other AND to the ROSTER above.
# A parse that finds nothing is a FAILURE, never a silent skip: the anchors below
# are the only thing standing between "the guard passed" and "the guard is gone".
agent_providers() {
  grep -E '"\$PROVIDER" != "' "$ROOT/engine/agent.sh" \
    | grep -oE '!= "[A-Za-z0-9_-]+"' | sed -E 's/.*"(.*)"/\1/' | sort -u
}
chief_providers() {
  awk 'index($0,"case \"$provider\" in"){f=1;next} f&&/\)/{print;exit}' "$ROOT/bin/chief" \
    | sed -E 's/^[[:space:]]*//; s/\).*//' | tr '|' '\n' | sed '/^[[:space:]]*$/d' | sort -u
}

agent_list="$(agent_providers)"
chief_list="$(chief_providers)"
roster_list="$(roster_names)"
[ -n "$agent_list" ] || fail "could not parse the provider list out of engine/agent.sh — the guard's anchor moved; fix the parser in this file, do not delete the check"
[ -n "$chief_list" ] || fail "could not parse the provider list out of bin/chief cmd_run — the guard's anchor moved; fix the parser in this file, do not delete the check"

if [ "$agent_list" != "$chief_list" ]; then
  echo "engine/agent.sh accepts:" >&2; printf '  %s\n' $agent_list >&2
  echo "bin/chief cmd_run accepts:" >&2; printf '  %s\n' $chief_list >&2
  fail "the two validator lists have diverged (docs/guides/providers.md checklist item 3)"
fi
if [ "$agent_list" != "$roster_list" ]; then
  echo "validators accept:" >&2; printf '  %s\n' $agent_list >&2
  echo "this harness covers:" >&2; printf '  %s\n' $roster_list >&2
  fail "a provider is accepted but not conformance-tested (or vice versa) — register it in ROSTER above"
fi
note "roster-drift guard OK — agent.sh, bin/chief and this harness agree: $(echo $agent_list | tr '\n' ' ')"

# ── 2) THE SCRIPTED DOUBLE ───────────────────────────────────────────────────
# One script, copied under each provider's name. It records the exact argv it was
# invoked with (one arg per line, so the assertion is genuinely exact) and every
# byte it received on stdin, then does the minimum an agent must do for the loop
# to accept a completion: land a commit, then emit the token on a line by itself.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/_double" <<'SH'
#!/usr/bin/env bash
set -eu
: > "$PROVIDER_ARGV_LOG"
for a in "$@"; do printf '%s\n' "$a" >> "$PROVIDER_ARGV_LOG"; done
cat > "$PROVIDER_STDIN_LOG"
jq '(.userStories[0].passes)=true' .chief/state/prd.json > .chief/state/prd.tmp
mv .chief/state/prd.tmp .chief/state/prd.json
git add -A
git commit -q -m "conformance double: $(basename "$0")"
printf '%s\n' '<promise>COMPLETE</promise>'
SH
for r in "${ROSTER[@]}"; do
  cp "$WORK/fakebin/_double" "$WORK/fakebin/${r%%|*}"
  chmod +x "$WORK/fakebin/${r%%|*}"
done
rm -f "$WORK/fakebin/_double"

scratch_repo() {          # a minimal project agent.sh can complete in one iteration
  local repo="$1" sentinel="$2"
  mkdir -p "$repo/.chief/state"
  git -C "$repo" init -q -b main 2>/dev/null || git -C "$repo" init -q
  git -C "$repo" commit -q --allow-empty -m init
  cat > "$repo/.chief/state/prd.json" <<'JSON'
{"branchName":"chief/conformance","userStories":[{"id":"US-1","passes":false}]}
JSON
  # The agent-context file is appended VERBATIM to the composed prompt, so this
  # sentinel is how we prove the prompt reached the provider on its own channel.
  printf '%s\n' "$sentinel" > "$repo/agent-context.md"
  printf '%s\n' '# Chief Progress Log' > "$repo/.chief/state/progress.txt"
  git -C "$repo" add -A && git -C "$repo" commit -q -m scaffold
}

# run_case <name> <channel> <stance> <expected-argv> <model> <label>
run_case() {
  local name="$1" channel="$2" stance="$3" expected="$4" model="$5" label="$6"
  local repo="$WORK/case-$label" sentinel="CONFORMANCE-SENTINEL-$label"
  local argv_log="$WORK/$label.argv" stdin_log="$WORK/$label.stdin" out="$WORK/$label.out"
  scratch_repo "$repo" "$sentinel"

  # env -u: this suite may itself be running inside a chief worktree, whose driver
  # exports CHIEF_PRESET/CHIEF_TOOL into the environment — inheriting either would
  # resolve a different provider than the one under test.
  ( cd "$repo" && env -u CHIEF_PRESET -u CHIEF_TOOL -u CHIEF_VERBOSE \
      PROVIDER_ARGV_LOG="$argv_log" PROVIDER_STDIN_LOG="$stdin_log" \
      CHIEF_PROVIDER="$name" CHIEF_MODEL="$model" \
      CHIEF_PROJECT="$repo" CHIEF_HOME="$ROOT/engine" CHIEF_STATE_DIR=.chief/state \
      CHIEF_AGENT_CONTEXT=agent-context.md \
      PATH="$WORK/fakebin:$PATH" "$ROOT/engine/agent.sh" 1 ) >"$out" 2>&1
  local rc=$?
  # A fake that commits and emits the token on its own line must end the loop at 0.
  [ "$rc" = 0 ] || { sed -n '1,40p' "$out" >&2; fail "$label: agent.sh exited $rc, not 0 (a committed COMPLETE must end the loop)"; }
  [ -f "$argv_log" ] || fail "$label: the $name double was never invoked"
  [ "$(git -C "$repo" rev-list --count HEAD)" -gt 2 ] || fail "$label: the double's commit did not land"

  # 2a) EXACT argv, one arg per line.
  local want="$WORK/$label.want"
  expected="${expected//%MODEL%/$model}"
  expected="${expected//%PROMPT_FILE%/$repo/.chief/state/.prompt.md}"
  # shellcheck disable=SC2086  # deliberate word-split: the expectation is space-separated argv
  printf '%s\n' $expected > "$want"
  if ! diff -u "$want" "$argv_log" >"$WORK/$label.diff" 2>&1; then
    cat "$WORK/$label.diff" >&2
    fail "$label: the engine composed different argv than the roster records (-want +got)"
  fi

  # 2b) Prompt delivery on the DOCUMENTED channel.
  case "$channel" in
    stdin)
      grep -q "$sentinel" "$stdin_log" \
        || fail "$label: the composed prompt did not reach $name on stdin"
      ;;
    prompt-file)
      grep -qx -- '--prompt-file' "$argv_log" \
        || fail "$label: $name documents prompt-file delivery but no --prompt-file arg was passed"
      local pf; pf="$(grep -A1 -x -- '--prompt-file' "$argv_log" | tail -1)"
      [ -f "$pf" ] || fail "$label: --prompt-file pointed at a nonexistent path ($pf)"
      grep -q "$sentinel" "$pf" \
        || fail "$label: the file handed to $name via --prompt-file did not carry the composed prompt"
      ;;
    *) fail "$label: unknown prompt channel '$channel' in the ROSTER" ;;
  esac

  # 2c) The model stance. `wired` is proven by the argv diff above; `unwired`
  #     additionally forbids the value from leaking into argv at all — that is
  #     what distinguishes a recorded "no model flag" from an accidental drop.
  if [ "$stance" = unwired ] && [ -n "$model" ]; then
    grep -q -- "$model" "$argv_log" \
      && fail "$label: $name is recorded as model-unwired but '$model' reached its argv"
  fi
}

for r in "${ROSTER[@]}"; do
  IFS='|' read -r name channel stance argv_model argv_plain <<<"$r"
  [ -n "$name" ] && [ -n "$channel" ] && [ -n "$stance" ] && [ -n "$argv_model" ] && [ -n "$argv_plain" ] \
    || fail "malformed ROSTER entry: $r"
  case "$stance" in
    wired|unwired) ;;
    *) fail "$name: unknown model stance '$stance' (expected wired|unwired)" ;;
  esac
  case "$argv_model" in
    *%MODEL%*) [ "$stance" = wired ] || fail "$name: registered 'unwired' but its argv interpolates %MODEL%" ;;
    *)         [ "$stance" = unwired ] || fail "$name: registered 'wired' but its argv never interpolates %MODEL%" ;;
  esac
  note "$name — argv · $channel prompt · model:$stance"
  run_case "$name" "$channel" "$stance" "$argv_model" "conformance/test-model" "$name-model"
  run_case "$name" "$channel" "$stance" "$argv_plain" ""                       "$name-plain"
done

# ── 3) BOTH VALIDATORS BEHAVE LIKE THEIR LISTS ───────────────────────────────
# The textual guard above proves the two lists match; this proves the lists are
# the ones actually enforced — accepted names get through, an unknown one is
# refused by BOTH, with each command's documented exit code.
REPO="$WORK/cli"; mkdir -p "$REPO"
( cd "$REPO" \
  && { git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }; } \
  && git commit -q --allow-empty -m init \
  && "$CHIEF" init >/dev/null \
  && rm -f tasks/chief/example.json \
  && cat > tasks/chief/conf.json <<'JSON'
{"project":"conf","branchName":"chief/conf","description":"roster","iters":1,"dependsOn":[],"touches":[],"warmup":[],"userStories":[]}
JSON
) || fail "could not scaffold the CLI scratch repo"

for p in $agent_list; do
  out="$( cd "$REPO" && env -u CHIEF_PRESET -u CHIEF_TOOL -u CHIEF_PROVIDER -u CHIEF_MODEL \
            "$CHIEF" run -n --provider "$p" conf 2>&1 )" \
    || { echo "$out" >&2; fail "bin/chief rejected '$p', which its own validator list accepts"; }
  case "$out" in *"provider=$p"*) ;; *) echo "$out" >&2; fail "bin/chief did not schedule '$p'" ;; esac
done

out="$( cd "$REPO" && env -u CHIEF_PRESET -u CHIEF_TOOL -u CHIEF_PROVIDER -u CHIEF_MODEL \
          "$CHIEF" run -n --provider notaprovider conf 2>&1 )"; rc=$?
[ "$rc" = 2 ] || { echo "$out" >&2; fail "chief run accepted an unknown provider (exit $rc, expected 2)"; }

# ── 4) THE ROSTER'S CLI SURFACE ──────────────────────────────────────────────
# Two per-provider surfaces that used to be on the honour system (amp had neither):
#   • the --<provider> shorthand (checklist item 4) — asserted for EVERY provider,
#   • the model stance (checklist item 1 / #model-overrides) — an `unwired` provider
#     must REFUSE an explicit --model, never accept-and-ignore it.
for r in "${ROSTER[@]}"; do
  IFS='|' read -r name _ stance _ _ <<<"$r"
  out="$( cd "$REPO" && env -u CHIEF_PRESET -u CHIEF_TOOL -u CHIEF_PROVIDER -u CHIEF_MODEL \
            "$CHIEF" run -n "--$name" conf 2>&1 )" \
    || { echo "$out" >&2; fail "chief run --$name failed — every provider gets a shorthand (checklist item 4)"; }
  case "$out" in *"provider=$name"*) ;; *) echo "$out" >&2; fail "chief run --$name did not select provider '$name'" ;; esac

  if [ "$stance" = unwired ]; then
    out="$( cd "$REPO" && env -u CHIEF_PRESET -u CHIEF_TOOL -u CHIEF_PROVIDER -u CHIEF_MODEL \
              "$CHIEF" run -n --provider "$name" --model conformance/test-model conf 2>&1 )"; rc=$?
    [ "$rc" = 2 ] || { echo "$out" >&2; fail "$name is model-unwired but 'chief run --model' was accepted (exit $rc, expected 2) — accept-and-ignore is barred"; }
    case "$out" in *"no model selector"*) ;; *) echo "$out" >&2; fail "$name refused --model without saying why" ;; esac
  fi
done
note "CLI surface OK — a --<provider> shorthand for each, and every unwired provider refuses --model"

repo="$WORK/case-bogus"; scratch_repo "$repo" CONFORMANCE-SENTINEL-bogus
out="$( cd "$repo" && env -u CHIEF_PRESET -u CHIEF_TOOL \
          CHIEF_PROVIDER=notaprovider CHIEF_PROJECT="$repo" CHIEF_HOME="$ROOT/engine" \
          CHIEF_STATE_DIR=.chief/state PATH="$WORK/fakebin:$PATH" \
          "$ROOT/engine/agent.sh" 1 2>&1 )"; rc=$?
[ "$rc" = 1 ] || { echo "$out" >&2; fail "agent.sh accepted an unknown provider (exit $rc, expected 1)"; }
case "$out" in *"Invalid provider"*) ;; *) echo "$out" >&2; fail "agent.sh did not report an invalid provider" ;; esac

echo "PROVIDER-CONFORMANCE PASS — $(echo $agent_list | wc -w | tr -d ' ') providers: argv, prompt channel, model stance (wired propagates, unwired refuses), shorthand, completion; validators in lockstep"
