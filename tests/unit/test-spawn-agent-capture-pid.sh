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
#
# Exercises the real spawn_agent_capture_pid default (spawn.sh:1125) with both
# calls actually backgrounded and racing, not run one after another — a
# sequential invocation can't prove concurrent callers stay distinct.
test_case "capture_pid default task_id does not collide across concurrent same-second calls"
date() { echo 1234567890; }  # freeze every call to the same second
unset RANDOM; RANDOM=42  # loses its special per-reference behavior once unset+reassigned (bash(1)); pins it so only PID entropy can distinguish the two concurrent calls
spawn_agent() {
    printf '%s\n' "$3" >> "$TEST_TMP_DIR/task_ids_capture_pid"
    printf '%s\n' 424242
}
export "OCTOPUS_SPAWN_PID_WAIT_ATTEMPTS=20"
: > "$TEST_TMP_DIR/task_ids_capture_pid"
spawn_agent_capture_pid codex prompt >/dev/null &
first_call=$!
spawn_agent_capture_pid gemini prompt >/dev/null &
second_call=$!
wait "$first_call"
wait "$second_call"
unset -f date
first_id=$(sed -n '1p' "$TEST_TMP_DIR/task_ids_capture_pid")
second_id=$(sed -n '2p' "$TEST_TMP_DIR/task_ids_capture_pid")
if [[ -n "$first_id" && -n "$second_id" && "$first_id" != "$second_id" ]]; then
    test_pass
else
    test_fail "expected distinct default task_ids, got '$first_id' and '$second_id'"
fi

# Direct coverage for spawn_agent's own default (spawn.sh:140/143), which the
# capture_pid test above never reaches because it stubs spawn_agent out. Load
# the literal declaration lines rather than a hand-copied re-implementation,
# so this test tracks the real source instead of drifting from it.
test_case "spawn_agent default task_id does not collide across concurrent same-second calls"
eval "spawn_agent_default_task_id() {
$(sed -n '140,143p' "$PROJECT_ROOT/scripts/lib/spawn.sh")
    printf '%s\n' \"\$task_id\"
}"
date() { echo 1234567890; }
: > "$TEST_TMP_DIR/task_ids_direct"
# RANDOM is already pinned to a plain (non-special) 42 from the prior test case
{ spawn_agent_default_task_id x y >> "$TEST_TMP_DIR/task_ids_direct"; } &
first_call=$!
{ spawn_agent_default_task_id x y >> "$TEST_TMP_DIR/task_ids_direct"; } &
second_call=$!
wait "$first_call"
wait "$second_call"
unset -f date
first_id=$(sed -n '1p' "$TEST_TMP_DIR/task_ids_direct")
second_id=$(sed -n '2p' "$TEST_TMP_DIR/task_ids_direct")
if [[ -n "$first_id" && -n "$second_id" && "$first_id" != "$second_id" ]]; then
    test_pass
else
    test_fail "expected distinct default task_ids, got '$first_id' and '$second_id'"
fi

test_summary
