#!/usr/bin/env bash
# Shared strict wall-clock bound for startup and readiness probes.

[[ -n "${_OCTOPUS_BOUNDED_PROBE_LOADED:-}" ]] && return 0
_OCTOPUS_BOUNDED_PROBE_LOADED=true

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

# Keep the full process tree inside a strict total wall-clock budget. Reserve a
# caller-selected grace period inside that budget, rather than adding it after
# the timeout expires.
_octo_run_bare_probe_with_timeout() {
    local total_timeout="$1"
    local term_timeout="$2"
    local kill_grace="$3"
    shift 3

    # Always own a private process group. Generic timeout utilities can return
    # when a wrapper exits successfully while leaving its background children
    # alive, which violates this helper's whole-tree contract.
    local cmd_pid monitor_pid exit_code timeout_marker timed_out=false
    timeout_marker="$(umask 077 && mktemp "${TMPDIR:-/tmp}/octo-probe-timeout.XXXXXX")" || return 125
    printf '%s\n' pending > "$timeout_marker" || { rm -f "$timeout_marker"; return 125; }
    if command -v setsid >/dev/null 2>&1; then
        setsid "$@" <&0 &
    elif command -v perl >/dev/null 2>&1; then
        perl -MPOSIX -e \
            'defined POSIX::setsid() or exit 125; exec @ARGV; exit 126' \
            -- "$@" <&0 &
    else
        rm -f "$timeout_marker"
        return 125
    fi
    cmd_pid=$!

    if command -v perl >/dev/null 2>&1; then
        perl -e '
            my ($term_timeout, $kill_grace, $pid, $marker) = @ARGV;
            select undef, undef, undef, $term_timeout;
            if (open my $fh, ">", $marker) {
                print {$fh} "timed-out\n";
                close $fh;
            }
            if ($kill_grace > 0) {
                kill "TERM", -$pid;
                select undef, undef, undef, $kill_grace;
            }
            kill "KILL", -$pid;
        ' "$term_timeout" "$kill_grace" "$cmd_pid" "$timeout_marker" </dev/null >/dev/null 2>&1 &
    else
        (
            sleep "$term_timeout"
            printf '%s\n' timed-out > "$timeout_marker"
            if [[ "$kill_grace" -gt 0 ]]; then
                kill -TERM -- "-$cmd_pid" 2>/dev/null || true
                sleep "$kill_grace"
            fi
            kill -KILL -- "-$cmd_pid" 2>/dev/null || true
        ) </dev/null >/dev/null 2>&1 &
    fi
    monitor_pid=$!

    if wait "$cmd_pid" 2>/dev/null; then
        exit_code=0
    else
        exit_code=$?
    fi
    [[ "$(cat "$timeout_marker" 2>/dev/null)" == timed-out ]] && timed_out=true
    pkill -KILL -P "$monitor_pid" 2>/dev/null || true
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    kill -KILL -- "-$cmd_pid" 2>/dev/null || true
    rm -f "$timeout_marker"
    [[ "$timed_out" == true ]] && return 124
    return "$exit_code"
}
