#!/usr/bin/env bash
# Select external consultative advisors from the authoritative fleet builder.
# Propagates fleet-construction failures and emits a comma-delimited provider list.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ALLOWLIST_LIB="${SCRIPT_DIR}/../lib/provider-allowlist.sh"
FLEET_BUILDER="${OCTOPUS_FLEET_BUILDER:-${SCRIPT_DIR}/build-fleet.sh}"

if [[ $# -lt 3 ]]; then
    printf 'Usage: %s <research|debate> <intensity> <prompt>\n' "$0" >&2
    exit 64
fi

workflow="$1"
intensity="$2"
prompt="$3"
case "$workflow" in
    research|debate) ;;
    *)
        printf 'ERROR: unsupported advisor workflow: %s\n' "$workflow" >&2
        exit 64
        ;;
esac

if [[ ! -r "$ALLOWLIST_LIB" ]]; then
    printf 'ERROR: required provider allowlist library is not readable: %s\n' "$ALLOWLIST_LIB" >&2
    exit 1
fi
# shellcheck source=../lib/provider-allowlist.sh
source "$ALLOWLIST_LIB"

if [[ ! -r "$FLEET_BUILDER" ]]; then
    printf 'ERROR: fleet builder is not readable: %s\n' "$FLEET_BUILDER" >&2
    exit 1
fi

fleet_output="$(bash "$FLEET_BUILDER" "$workflow" "$intensity" "$prompt")"
fleet_status=$?
if [[ "$fleet_status" -ne 0 ]]; then
    exit "$fleet_status"
fi

advisors=""
while IFS='|' read -r provider label _perspective; do
    [[ -n "$provider" ]] || continue
    case "$workflow:$label" in
        debate:Debater) ;;
        debate:*) continue ;;
    esac
    case "$provider" in
        claude*|kimi*) continue ;;
        codex*|commandcode*|grok*|agy*|gemini*|antigravity|copilot*|qwen*|\
        cursor-agent*|opencode*|ollama*|vibe*|openrouter*|\
        openai-compatible*|atlascloud-agent*|perplexity*) ;;
        *) continue ;;
    esac
    octo_provider_allowed "$provider" || continue
    case ",$advisors," in
        *",$provider,"*) continue ;;
    esac
    advisors="${advisors:+$advisors,}${provider}"
done <<EOF
$fleet_output
EOF

if [[ -z "$advisors" ]]; then
    printf 'ERROR: no eligible external advisors are available for the %s workflow\n' "$workflow" >&2
    exit 1
fi

printf '%s\n' "$advisors"
