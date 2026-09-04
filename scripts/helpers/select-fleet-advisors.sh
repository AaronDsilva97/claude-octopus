#!/usr/bin/env bash
# Select external consultative advisors from the authoritative fleet builder.
# Propagates fleet-construction failures and emits a comma-delimited provider list.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CONSULTATIVE_LIB="${SCRIPT_DIR}/../lib/consultative-advisors.sh"
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

if [[ ! -r "$CONSULTATIVE_LIB" ]]; then
    printf 'ERROR: consultative advisor library is not readable: %s\n' "$CONSULTATIVE_LIB" >&2
    exit 1
fi
# shellcheck source=../lib/consultative-advisors.sh
source "$CONSULTATIVE_LIB"

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
    octo_consultative_provider_is_launchable "$provider" || continue
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
