#!/usr/bin/env bash
# Shared strict wall-clock bound for startup and readiness probes.

[[ -n "${_OCTOPUS_BOUNDED_PROBE_LOADED:-}" ]] && return 0
_OCTOPUS_BOUNDED_PROBE_LOADED=true

_octo_bounded_probe_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Load the shared supervisor while the caller still has its normal utility
# path. Bare-probe tests and hardened hosts may deliberately narrow PATH before
# executing the probe itself.
if ! declare -f run_with_timeout >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${_octo_bounded_probe_lib_dir}/heartbeat.sh" 2>/dev/null || true
fi

# Normalize before arithmetic: Bash 3.2 wraps sufficiently long digit strings,
# which can otherwise turn an oversized value into a small positive timeout.
_octo_bare_probe_timeout() {
    local value="${1:-5}"

    case "$value" in
        ''|*[!0-9]*) printf '%s\n' 5; return ;;
    esac
    while [[ "$value" == 0* ]]; do
        value="${value#0}"
    done
    case "$value" in
        '') printf '%s\n' 5 ;;
        [1-9]|[1-2][0-9]|30) printf '%s\n' "$value" ;;
        *) printf '%s\n' 30 ;;
    esac
}

_octo_bare_probe_budget() {
    local total_timeout term_timeout kill_grace
    total_timeout="$(_octo_bare_probe_timeout "${1:-5}")"
    term_timeout="$total_timeout"
    kill_grace=0
    if [[ "$total_timeout" -gt 2 ]]; then
        kill_grace=2
        term_timeout=$((total_timeout - kill_grace))
    fi
    printf '%s %s %s\n' "$total_timeout" "$term_timeout" "$kill_grace"
}

# Keep the provider process group inside a strict wall-clock budget. The shared
# portable supervisor creates and owns a private process group without reading
# the process table, so startup latency and cleanup cannot postpone the deadline.
# A child that deliberately creates a new session is outside this portable
# containment boundary and requires an OS-native supervisor.
_octo_run_bare_probe_with_timeout() {
    local total_timeout="$1"
    local term_timeout="$2"
    local kill_grace="$3"
    shift 3

    [[ "$total_timeout" -eq $((term_timeout + kill_grace)) ]] || return 125
    declare -f run_with_timeout >/dev/null 2>&1 || return 125

    OCTOPUS_TIMEOUT_KILL_GRACE="$kill_grace" \
        run_with_timeout --portable-supervisor "$term_timeout" "$@"
}
