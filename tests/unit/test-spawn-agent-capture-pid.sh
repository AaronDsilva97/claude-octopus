#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "spawn agent PID capture"

# Load only the helper under test so the fixture controls spawn_agent and log.
eval "$(sed -n '/^spawn_agent_capture_pid() {/,/^}/p' "$PROJECT_ROOT/scripts/lib/spawn.sh")"

TEST_TMP_DIR="/tmp/octopus-tests-$$"
mkdir -p "$TEST_TMP_DIR"
trap 'rm -rf "$TEST_TMP_DIR"' EXIT INT TERM

log() { printf '%s %s\n' "${1:-}" "${2:-}" >> "$TEST_TMP_DIR/log"; }

# The wrapper does meaningful setup before it can print the provider PID.
# Capture must wait for that PID rather than returning the wrapper PID.
test_case "returns delayed provider PID rather than wrapper PID"
spawn_agent() {
    sleep 0.3
    printf '%s\n' 424242
}
export "OCTOPUS_SPAWN_PID_WAIT_ATTEMPTS=20"
pid=$(spawn_agent_capture_pid codex prompt delayed-task implementer tangle)
if [[ "$pid" == "424242" ]]; then
    test_pass
else
    test_fail "expected provider PID 424242, got: ${pid:-empty}"
fi

# A failed setup must fail dispatch. Returning the short-lived wrapper PID would
# make downstream wait loops report a false missing completion marker.
test_case "fails when spawn_agent exits without provider PID"
spawn_agent() {
    printf '%s\n' "setup failed before provider launch"
    return 1
}
export "OCTOPUS_SPAWN_PID_WAIT_ATTEMPTS=20"
if pid=$(spawn_agent_capture_pid codex prompt failed-task implementer tangle 2>/dev/null); then
    test_fail "expected failure, got wrapper/provider PID: ${pid:-empty}"
else
    test_pass
fi

test_case "implementation has no wrapper PID fallback"
if grep -q 'tracking wrapper PID' "$PROJECT_ROOT/scripts/lib/spawn.sh"; then
    test_fail "unsafe wrapper PID fallback still present"
else
    test_pass
fi

# Regression for #661: two concurrent spawns with no explicit task_id must not
# collide on the same-second `date +%s` value, or their result/temp files
# interleave and get attributed to the wrong provider.
test_case "default task_id does not collide across same-second calls"
date() { echo 1234567890; }  # freeze every call to the same second
spawn_agent() {
    printf '%s\n' "$3" >> "$TEST_TMP_DIR/task_ids"
    printf '%s\n' 424242
}
export "OCTOPUS_SPAWN_PID_WAIT_ATTEMPTS=20"
: > "$TEST_TMP_DIR/task_ids"
spawn_agent_capture_pid codex prompt >/dev/null
spawn_agent_capture_pid gemini prompt >/dev/null
unset -f date
first_id=$(sed -n '1p' "$TEST_TMP_DIR/task_ids")
second_id=$(sed -n '2p' "$TEST_TMP_DIR/task_ids")
if [[ -n "$first_id" && -n "$second_id" && "$first_id" != "$second_id" ]]; then
    test_pass
else
    test_fail "expected distinct default task_ids, got '$first_id' and '$second_id'"
fi

test_summary
