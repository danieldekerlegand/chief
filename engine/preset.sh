#!/usr/bin/env bash
# engine/preset.sh — named run PRESETS: one switch that resolves to a full
# provider · model · endpoint configuration.
#
# A preset is NOT a provider. It is a documented bundle over the EXISTING provider
# seam (engine/agent.sh's _run_provider), so everything downstream — the driver's
# dry-run line, `chief ps`/`monitor`, the event stream — keeps reporting the plain
# resolved provider·model it always did.
#
# Presets:
#   local — COST AVOIDANCE. Routes agent turns through the opencode dispatch against
#           a LOCAL / self-hosted OpenAI-compatible inference server, so high-volume
#           agentic testing costs nothing per token. The tradeoff is deliberate and
#           not small: local models code materially worse than a frontier model. Pick
#           this for volume (soak runs, harness testing, throwaway branches), not for
#           work you intend to ship.
#
# Configuration (env, or the project's .chief/config — NO host is hard-coded here):
#   CHIEF_LOCAL_ENDPOINT       required — base URL of the local server, e.g.
#                              http://127.0.0.1:11434/v1 (ollama) or :1234/v1 (LM Studio)
#   CHIEF_LOCAL_MODEL          required — model id to ask that server for
#                              (`chief models opencode` lists what it serves)
#   CHIEF_LOCAL_ENDPOINT_ENV   optional — env var the endpoint is published as
#                              (default OPENAI_BASE_URL, what OpenAI-compatible
#                              OpenCode providers read)
#   CHIEF_LOCAL_API_KEY        optional — placeholder credential local servers accept
#                              but SDKs still require non-empty (default "local")
#   CHIEF_LOCAL_API_KEY_ENV    optional — env var that key is published as
#                              (default OPENAI_API_KEY)
#
# Unconfigured, the preset FAILS with the missing variable names. It never quietly
# degrades to the default provider: the whole point is spending no money, and a
# silent fallback to a paid frontier model is the one outcome the operator asked
# for protection from.
#
# bash 3.2: no associative arrays, no ${var^^}, no `declare -g`.

# chief_preset_resolve — resolve $CHIEF_PRESET into CHIEF_PROVIDER / CHIEF_MODEL and
# export whatever env the preset's backend needs. Operates on GLOBALS in the caller's
# shell (it must export into the process that later spawns the provider), so call it
# plainly — never in $(...).
#
# In:  CHIEF_PRESET      preset name ("" = nothing to do, returns 0)
#      CHIEF_PROVIDER    provider the caller was EXPLICITLY given ("" if none). A
#                        conflicting explicit provider is an error, not a silent
#                        override — `--preset local --provider claude` is ambiguous
#                        about which one is paying.
#      CHIEF_MODEL       model the caller was explicitly given ("" if none)
# Out: CHIEF_PROVIDER, CHIEF_MODEL set; backend env exported.
# Returns 0 on success, non-zero (message on stderr) when the preset is unknown or
# its required configuration is absent.
chief_preset_resolve() {
  local preset="${CHIEF_PRESET:-}"
  [ -n "$preset" ] || return 0

  case "$preset" in
    local) _chief_preset_local ;;
    *)
      echo "chief: unknown preset '$preset' (known presets: local)" >&2
      return 2
      ;;
  esac
}

_chief_preset_local() {
  local missing="" endpoint_env key_env

  [ -n "${CHIEF_LOCAL_ENDPOINT:-}" ] || missing="$missing
  CHIEF_LOCAL_ENDPOINT   base URL of your local OpenAI-compatible inference server
                         (e.g. http://127.0.0.1:11434/v1)"
  [ -n "${CHIEF_LOCAL_MODEL:-}" ] || missing="$missing
  CHIEF_LOCAL_MODEL      model id to ask that server for
                         (list what it serves with: chief models opencode)"

  if [ -n "$missing" ]; then
    {
      echo "chief: preset 'local' is not configured. Set:"
      echo "$missing"
      echo "  in the environment or <repo>/.chief/config, then re-run."
      echo "  Refusing to fall back to a paid provider — that is what this preset exists to avoid."
    } >&2
    return 2
  fi

  # The preset IS the provider choice. An explicit, different provider means the
  # operator asked for two mutually exclusive things.
  if [ -n "${CHIEF_PROVIDER:-}" ] && [ "$CHIEF_PROVIDER" != opencode ]; then
    echo "chief: preset 'local' resolves to provider 'opencode', but provider '$CHIEF_PROVIDER' was requested — pick one." >&2
    return 2
  fi
  if [ -n "${CHIEF_MODEL:-}" ] && [ "$CHIEF_MODEL" != "$CHIEF_LOCAL_MODEL" ]; then
    echo "chief: preset 'local' resolves to model '$CHIEF_LOCAL_MODEL', but model '$CHIEF_MODEL' was requested — pick one." >&2
    return 2
  fi

  CHIEF_PROVIDER=opencode
  CHIEF_TOOL=opencode
  CHIEF_MODEL="$CHIEF_LOCAL_MODEL"
  export CHIEF_PROVIDER CHIEF_TOOL CHIEF_MODEL

  # Publish the endpoint (and the placeholder credential) under the names the local
  # backend reads. Both var NAMES are configurable so a non-OpenAI-shaped local
  # server is reachable without patching the engine.
  endpoint_env="${CHIEF_LOCAL_ENDPOINT_ENV:-OPENAI_BASE_URL}"
  key_env="${CHIEF_LOCAL_API_KEY_ENV:-OPENAI_API_KEY}"
  export "$endpoint_env=$CHIEF_LOCAL_ENDPOINT"
  export "$key_env=${CHIEF_LOCAL_API_KEY:-local}"
  return 0
}
