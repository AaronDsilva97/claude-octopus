#!/usr/bin/env bash
# Moonshot Kimi Code CLI stdin→argv shim. octo pipes prompts via stdin (spawn.sh
# contract); kimi's `-p/--prompt` takes the prompt as an argv argument, so read
# stdin and re-pass it. Model via OCTOPUS_KIMI_MODEL (default: kimi's own default
# from ~/.kimi-code/config.toml).
#
# Current Kimi Code uses -p/--prompt for non-interactive output and auto-approves
# tools in that mode. dispatch.sh therefore rejects Kimi for read-only roles.
set -euo pipefail

_kimi_exec_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_kimi_exec_dir}/../lib/kimi-model-name.sh" || {
    echo "kimi-exec: model validator unavailable" >&2
    exit 64
}

prompt=""
[[ ! -t 0 ]] && prompt="$(cat)"
if [[ -z "${prompt//[[:space:]]/}" ]]; then
    # Standalone shim (exec'd by dispatch.sh) — matches grok-exec.sh / vibe-exec.sh
    # which also use raw echo>&2 for startup validation (no shared logger in scope).
    echo "kimi-exec: no prompt provided on stdin" >&2
    exit 64
fi
if [[ "${OCTOPUS_KIMI_MODEL_HEX+x}" == x ]]; then
    # The validated dispatch token is authoritative. An ambient plaintext
    # override must not conflict with the exact model selected by dispatch.
    model="$(octopus_kimi_model_from_hex "$OCTOPUS_KIMI_MODEL_HEX")" || {
        echo "kimi-exec: invalid encoded model" >&2
        exit 64
    }
elif [[ "${OCTOPUS_KIMI_MODEL+x}" == x ]]; then
    model="$OCTOPUS_KIMI_MODEL"
    if ! octopus_kimi_model_name_is_safe "$model"; then
        echo "kimi-exec: invalid model" >&2
        exit 64
    fi
else
    model="default"
fi
cmd=(kimi -p "$prompt")
if [[ -n "$model" && "$model" != "default" ]]; then
    cmd+=(--model "$model")
fi
exec "${cmd[@]}"
