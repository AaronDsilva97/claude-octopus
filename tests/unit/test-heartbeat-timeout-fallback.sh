#!/bin/bash
# Regression coverage for the portable run_with_timeout fallback.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
log() { :; }
source "$PROJECT_ROOT/scripts/lib/heartbeat.sh"

test_suite "Heartbeat portable timeout fallback"

test_timeout_signals_root_without_ps() {
    test_case "portable timeout signals and reaps its root when ps fails"
    local target="$TEST_TMP_DIR/timeout-root.sh"
    local pid_file="$TEST_TMP_DIR/timeout-root.pid"
    local rc=0 started_ms elapsed_ms target_pid="" alive=false

    cat > "$target" <<'EOF'
#!/bin/bash
printf '%s\n' "$$" > "$1"
exec /bin/sleep 4
EOF
    chmod +x "$target"

    # Force the in-process path and simulate a harness that denies process
    # enumeration. The root PID is still known from `$!` and must be signalled.
    command() {
        if [[ "${1:-}" == "-v" && ( "${2:-}" == "gtimeout" || "${2:-}" == "timeout" ) ]]; then
            return 1
        fi
        builtin command "$@"
    }
    ps() { return 1; }

    started_ms="$(python3 -c 'import time; print(int(time.monotonic() * 1000))')"
    run_with_timeout 1 "$target" "$pid_file" >/dev/null 2>&1 || rc=$?
    elapsed_ms=$(( $(python3 -c 'import time; print(int(time.monotonic() * 1000))') - started_ms ))

    unset -f command ps
    [[ -s "$pid_file" ]] && target_pid="$(< "$pid_file")"
    if [[ -n "$target_pid" ]] && kill -0 "$target_pid" 2>/dev/null; then
        alive=true
        kill -KILL "$target_pid" 2>/dev/null || true
    fi

    if [[ "$rc" -eq 124 && -n "$target_pid" && "$alive" == false && "$elapsed_ms" -lt 3000 ]]; then
        test_pass
    else
        test_fail "expected rc=124, a reaped root, and <3000ms; got rc=$rc pid=${target_pid:-missing} alive=$alive elapsed=${elapsed_ms}ms"
    fi
}

test_pid_reuse_metadata_is_enforced() {
    test_case "timeout signalling retains PID start-time reuse protection"
    local victim_pid expected_started="Wed Sep  2 02:00:00 2026"
    local wrong_snapshot matching_snapshot
    local wrong_preserved=false matching_killed=false

    /bin/sleep 30 &
    victim_pid=$!
    FAKE_PROCESS_STARTED="$expected_started"
    ps() {
        case "$*" in
            *"stat="*) printf '%s\n' "S" ;;
            *"lstart="*) printf '%s\n' "$FAKE_PROCESS_STARTED" ;;
            *) return 1 ;;
        esac
    }
    wrong_snapshot="${victim_pid}"$'\t'"Tue Sep  1 02:00:00 2026"
    matching_snapshot="${victim_pid}"$'\t'"${expected_started}"

    _octo_timeout_signal_snapshot TERM "$wrong_snapshot"
    kill -0 "$victim_pid" 2>/dev/null && wrong_preserved=true
    _octo_timeout_signal_snapshot TERM "$matching_snapshot"
    wait "$victim_pid" 2>/dev/null || true
    kill -0 "$victim_pid" 2>/dev/null || matching_killed=true
    unset -f ps
    unset FAKE_PROCESS_STARTED

    if [[ "$wrong_preserved" == true && "$matching_killed" == true ]]; then
        test_pass
    else
        kill -KILL "$victim_pid" 2>/dev/null || true
        wait "$victim_pid" 2>/dev/null || true
        test_fail "matching start metadata should pass and mismatched metadata should reject the PID"
    fi
}

test_timeout_signals_root_without_ps
test_pid_reuse_metadata_is_enforced

test_summary
