#!/bin/bash
# tests/unit/test-seat-kill-status-leaks.sh
# Regression coverage for #751: bare `kill`/`wait`/`pkill` statements on a
# monitor/child PID that has already exited return non-zero and, under the
# orchestrator's `set -eo pipefail`, abort the enclosing function *after* the
# real work already succeeded. #739 fixed one instance of this in perplexity.sh;
# this covers the five remaining sites (workflows.sh, cursor-agent.sh x2,
# heartbeat.sh x2) named in #751.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "Seat kill/wait status leaks (#751)"

# Behavioral proof of the underlying failure mode: a bare `kill`/`wait` on an
# already-reaped PID aborts a `set -e` shell before later statements run.
test_bare_kill_wait_aborts_under_set_e() {
    test_case "bare kill/wait on a reaped PID aborts under set -e (unguarded control)"

    local out
    out=$(bash -c '
        set -e
        ( sleep 0.05 ) & m=$!
        wait "$m" 2>/dev/null
        kill "$m" 2>/dev/null
        echo REACHED-END
    ' 2>/dev/null) || true

    if [[ "$out" != *"REACHED-END"* ]]; then
        test_pass
    else
        test_fail "expected the unguarded kill to abort the shell before REACHED-END; got: $out"
    fi
}

test_guarded_kill_wait_survives_under_set_e() {
    test_case "|| true guarded kill/wait survives under set -e"

    local out
    out=$(bash -c '
        set -e
        ( sleep 0.05 ) & m=$!
        wait "$m" 2>/dev/null || true
        kill "$m" 2>/dev/null || true
        echo REACHED-END
    ' 2>/dev/null) || true

    if [[ "$out" == *"REACHED-END"* ]]; then
        test_pass
    else
        test_fail "expected REACHED-END after guarded kill/wait; got: $out"
    fi
}

# Static checks: each of the five sites named in #751 now guards its
# kill/wait so a bare, unguarded regression can't creep back in.
test_workflows_monitor_stop_guarded() {
    test_case "workflows.sh: synthesis monitor kill/wait guarded"

    local block
    block=$(sed -n '/Stop progressive synthesis monitor/,/^    fi$/p' "$PROJECT_ROOT/scripts/lib/workflows.sh")

    if grep -q 'kill "\$synthesis_monitor_pid" 2>/dev/null || true' <<< "$block" && \
       grep -q 'wait "\$synthesis_monitor_pid" 2>/dev/null || true' <<< "$block"; then
        test_pass
    else
        test_fail "synthesis_monitor_pid kill/wait is not guarded with || true"
    fi
}

test_cursor_agent_monitor_and_wait_guarded() {
    test_case "cursor-agent.sh: fallback monitor kill/wait guarded, exit code preserved"

    local fn
    fn=$(sed -n '/_cursor_agent_run_with_timeout()/,/^}/p' "$PROJECT_ROOT/scripts/lib/cursor-agent.sh")

    if grep -q 'kill -TERM "\$cmd_pid" 2>/dev/null || true' <<< "$fn" && \
       grep -q 'kill -KILL "\$cmd_pid" 2>/dev/null || true' <<< "$fn" && \
       grep -Fq 'if wait "$cmd_pid" 2>/dev/null; then' <<< "$fn"; then
        test_pass
    else
        test_fail "cursor-agent fallback timeout monitor/wait is not guarded"
    fi
}

test_heartbeat_monitor_guarded() {
    test_case "heartbeat.sh: run_with_timeout SIGTERM/SIGKILL kill guarded"

    local fn
    fn=$(sed -n '/run_with_timeout()/,/^}/p' "$PROJECT_ROOT/scripts/lib/heartbeat.sh")

    if grep -q 'kill -TERM "\$cmd_pid" 2>/dev/null || true' <<< "$fn" && \
       grep -q 'kill -KILL "\$cmd_pid" 2>/dev/null || true' <<< "$fn"; then
        test_pass
    else
        test_fail "heartbeat.sh run_with_timeout SIGTERM/SIGKILL kill is not guarded"
    fi
}

test_cursor_agent_exit_code_preserved() {
    test_case "cursor-agent.sh: real exit code of \"\$@\" still reaches the 137/143 check"

    local fn
    fn=$(sed -n '/_cursor_agent_run_with_timeout()/,/^}/p' "$PROJECT_ROOT/scripts/lib/cursor-agent.sh")

    # A prior version of the fix used a bare `|| true` here, which would have
    # silently forced exit_code=0 regardless of what "$@" actually returned.
    if grep -Fq 'if wait "$cmd_pid" 2>/dev/null; then' <<< "$fn" && \
       grep -Fq 'exit_code=$?' <<< "$fn"; then
        test_pass
    else
        test_fail "exit_code capture for \"\$@\" appears to have been lost or short-circuited"
    fi
}

test_bare_kill_wait_aborts_under_set_e
test_guarded_kill_wait_survives_under_set_e
test_workflows_monitor_stop_guarded
test_cursor_agent_monitor_and_wait_guarded
test_heartbeat_monitor_guarded
test_cursor_agent_exit_code_preserved

test_summary
