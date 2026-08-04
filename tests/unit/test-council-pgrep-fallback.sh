#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
source "$PROJECT_ROOT/scripts/lib/council.sh"

test_suite "Council cancellation without pgrep"

TEST_TMP_DIR="${TEST_TMP_DIR:-/tmp/octopus-tests-$$}"
trap 'rm -rf "$TEST_TMP_DIR"' EXIT
rm -rf "$TEST_TMP_DIR"
mkdir -p "$TEST_TMP_DIR/bin"
ln -s "$(command -v ps)" "$TEST_TMP_DIR/bin/ps"
ln -s "$(command -v sleep)" "$TEST_TMP_DIR/bin/sleep"

process_is_executable() {
    local pid="$1" state
    state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    [[ -n "$state" && "$state" != Z* ]]
}

process_is_active() {
    local pid="$1" state
    state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)
    [[ -n "$state" && "$state" != Z* ]]
}

test_case "ps fallback enumerates the exact direct child"
(
    sleep 5 &
    echo $! > "$TEST_TMP_DIR/direct-child.pid"
    wait
) &
parent=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s "$TEST_TMP_DIR/direct-child.pid" ]] && break
    /bin/sleep 0.05
done
direct_child=$(cat "$TEST_TMP_DIR/direct-child.pid")
children=$(PATH="$TEST_TMP_DIR/bin"; _council_child_pids "$parent")
_council_kill_descendants_frozen "$parent"
kill -KILL "$parent" 2>/dev/null || true
wait "$parent" 2>/dev/null || true
if [[ "$children" == "$direct_child" ]]; then
    test_pass
else
    test_fail "ps fallback expected direct child $direct_child, got: $children"
fi

test_case "cancellation terminates every direct and nested child without pgrep"
(
    trap '' HUP INT TERM
    trap 'exit 143' USR1
    (
        /bin/sleep 3
        : > "$TEST_TMP_DIR/child.mark"
    ) &
    echo $! > "$TEST_TMP_DIR/nested-child.pid"
    /bin/sleep 3 &
    echo $! > "$TEST_TMP_DIR/direct-sleep.pid"
    wait $!
    : > "$TEST_TMP_DIR/late.response"
) &
seat=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s "$TEST_TMP_DIR/nested-child.pid" && -s "$TEST_TMP_DIR/direct-sleep.pid" ]] && break
    /bin/sleep 0.05
done
nested_child=$(cat "$TEST_TMP_DIR/nested-child.pid")
direct_sleep=$(cat "$TEST_TMP_DIR/direct-sleep.pid")
( PATH="$TEST_TMP_DIR/bin"; _council_cancel_tree "$seat" )
wait "$seat" 2>/dev/null || true
/bin/sleep 0.3
seat_alive=no
nested_alive=no
direct_sleep_alive=no
process_is_active "$seat" && seat_alive=yes
process_is_active "$nested_child" && nested_alive=yes
process_is_active "$direct_sleep" && direct_sleep_alive=yes
if [[ "$seat_alive" == no && "$nested_alive" == no && "$direct_sleep_alive" == no && \
      ! -e "$TEST_TMP_DIR/child.mark" && ! -e "$TEST_TMP_DIR/late.response" ]]; then
    test_pass
else
    test_fail "seat=$seat_alive nested=$nested_alive direct_sleep=$direct_sleep_alive marker=$([[ -e "$TEST_TMP_DIR/child.mark" ]] && echo yes || echo no) late=$([[ -e "$TEST_TMP_DIR/late.response" ]] && echo yes || echo no)"
fi

test_summary
