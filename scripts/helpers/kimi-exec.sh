#!/usr/bin/env bash
# Moonshot Kimi Code CLI stdin→argv shim. octo pipes prompts via stdin (spawn.sh
# contract); kimi's `-p/--prompt` takes the prompt as an argv argument, so read
# stdin and re-pass it. Model via OCTOPUS_KIMI_MODEL (default: kimi's own default
# from ~/.kimi-code/config.toml).
#
# Do NOT add --auto here: kimi rejects it outright with
#   error: Cannot combine --prompt with --auto.
# -p is already a single-turn non-interactive run, so there is no prompt to
# auto-approve.
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
plaintext_model_set=false
plaintext_model=""
if [[ "${OCTOPUS_KIMI_MODEL+x}" == x ]]; then
    plaintext_model_set=true
    plaintext_model="$OCTOPUS_KIMI_MODEL"
    if ! octopus_kimi_model_name_is_safe "$plaintext_model"; then
        echo "kimi-exec: invalid model" >&2
        exit 64
    fi
fi
if [[ "${OCTOPUS_KIMI_MODEL_HEX+x}" == x ]]; then
    model="$(octopus_kimi_model_from_hex "$OCTOPUS_KIMI_MODEL_HEX")" || {
        echo "kimi-exec: invalid encoded model" >&2
        exit 64
    }
    if [[ "$plaintext_model_set" == true && "$plaintext_model" != "$model" ]]; then
        echo "kimi-exec: encoded model does not match isolated model" >&2
        exit 64
    fi
elif [[ "$plaintext_model_set" == true ]]; then
    model="$plaintext_model"
else
    model="default"
fi
cmd=(kimi -p "$prompt" --output-format text)
if [[ -n "$model" && "$model" != "default" ]]; then
    cmd+=(--model "$model")
fi
exec "${cmd[@]}"
