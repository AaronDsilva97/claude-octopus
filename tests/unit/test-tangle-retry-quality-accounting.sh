#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TESTING="$PROJECT_ROOT/scripts/lib/testing.sh"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/../helpers/test-framework.sh"
# shellcheck source=/dev/null
source "$TESTING"

test_suite "tangle retry quality accounting"

RED=""
GREEN=""
YELLOW=""
NC=""
DIM=""
_BOX_TOP=""
_BOX_BOT=""
LOOP_UNTIL_APPROVED=false
CI_MODE=true
OCTOPUS_ANTISYCOPHANCY=false
OCTOPUS_FILE_VALIDATION=false
MAX_QUALITY_RETRIES=0
FAILED_SUBTASKS=""

log() { :; }
record_task_metric() { :; }
write_structured_decision() { :; }
retry_failed_subtasks() { :; }
get_gate_threshold() { echo 75; }
evaluate_quality_branch() {
    if [[ "$1" -ge 75 ]]; then echo proceed; else echo abort; fi
}

RESULTS_DIR="$TEST_TMP_DIR/tangle-retry-quality-accounting"
mkdir -p "$RESULTS_DIR"

write_result() {
    local file="$1"
    local task_id="$2"
    local role="$3"
    local status="$4"
    cat > "$file" <<EOF_RESULT
# Agent: commandcode
# Task ID: $task_id
# Role: $role
# Phase: tangle
# Prompt: retry accounting fixture

## Output
fixture output for $task_id

## Status: $status
EOF_RESULT
}

# Three tasks succeed initially; two coding tasks fail.
write_result "$RESULTS_DIR/commandcode-tangle-accounting-1.md" "tangle-accounting-1" implementer FAILED
write_result "$RESULTS_DIR/commandcode-tangle-accounting-2.md" "tangle-accounting-2" implementer FAILED
write_result "$RESULTS_DIR/commandcode-tangle-accounting-3.md" "tangle-accounting-3" researcher SUCCESS
write_result "$RESULTS_DIR/commandcode-tangle-accounting-4.md" "tangle-accounting-4" researcher SUCCESS
write_result "$RESULTS_DIR/commandcode-tangle-accounting-5.md" "tangle-accounting-5" researcher SUCCESS

# Retry 1 supersedes tasks 1 and 2: task 1 recovers, task 2 is still failing.
write_result "$RESULTS_DIR/commandcode-tangle-accounting-retry1-1.md" "tangle-accounting-retry1-1" implementer SUCCESS
write_result "$RESULTS_DIR/commandcode-tangle-accounting-retry1-2.md" "tangle-accounting-retry1-2" implementer FAILED

test_case "latest retry supersedes historical result in quality percentage"
if validate_tangle_results "accounting" "Assess retry quality accounting" >/dev/null 2>&1; then
    report=$(cat "$RESULTS_DIR/tangle-validation-accounting.md")
    if [[ "$report" == *"Success Rate: 80%"* ]] && \
       [[ "$report" == *"Successful: 4/5 result files"* ]] && \
       [[ "$report" == *"Failed: 1/5 result files"* ]]; then
        test_pass
    else
        test_fail "quality report did not use only the latest result per logical task"
    fi
else
    test_fail "quality gate failed because superseded historical failures were still counted"
fi

test_case "effective result set excludes superseded originals"
effective=$(tangle_effective_result_files "accounting")
if [[ "$effective" == *"retry1-1.md"* ]] && \
   [[ "$effective" == *"retry1-2.md"* ]] && \
   [[ "$effective" != *"accounting-1.md"* ]] && \
   [[ "$effective" != *"accounting-2.md"* ]]; then
    test_pass
else
    test_fail "effective result set retained superseded original task results"
fi

test_summary
