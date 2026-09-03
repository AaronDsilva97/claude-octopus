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

_kimi_decode_model_hex() {
    local encoded="$1" decoded="" byte
    local index=0
    [[ "$encoded" =~ ^([0-9A-Fa-f][0-9A-Fa-f])+$ ]] || return 1
    while [[ "$index" -lt "${#encoded}" ]]; do
        printf -v byte '%b' "\\x${encoded:index:2}" || return 1
        decoded="${decoded}${byte}"
        index=$((index + 2))
    done
    printf '%s' "$decoded"
}

prompt=""
[[ ! -t 0 ]] && prompt="$(cat)"
if [[ -z "${prompt//[[:space:]]/}" ]]; then
    # Standalone shim (exec'd by dispatch.sh) — matches grok-exec.sh / vibe-exec.sh
    # which also use raw echo>&2 for startup validation (no shared logger in scope).
    echo "kimi-exec: no prompt provided on stdin" >&2
    exit 64
fi
if [[ -n "${OCTOPUS_KIMI_MODEL_HEX:-}" ]]; then
    model="$(_kimi_decode_model_hex "$OCTOPUS_KIMI_MODEL_HEX")" || {
        echo "kimi-exec: invalid encoded model" >&2
        exit 64
    }
    if [[ -n "${OCTOPUS_KIMI_MODEL:-}" && "$OCTOPUS_KIMI_MODEL" != "$model" ]]; then
        echo "kimi-exec: encoded model does not match isolated model" >&2
        exit 64
    fi
else
    model="${OCTOPUS_KIMI_MODEL:-default}"
fi
cmd=(kimi -p "$prompt" --output-format text)
if [[ -n "$model" && "$model" != "default" ]]; then
    cmd+=(--model "$model")
fi
exec "${cmd[@]}"
