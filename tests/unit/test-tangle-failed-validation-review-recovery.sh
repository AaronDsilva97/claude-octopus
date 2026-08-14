#!/usr/bin/env bash
# Behavioral tests for failed-validation recovery into contextual review.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "tangle failed validation review recovery"

TMP_DIR="$TEST_TMP_DIR/recovery"
mkdir -p "$TMP_DIR"
export RESULTS_DIR="$TMP_DIR/results"
mkdir -p "$RESULTS_DIR"

run_decision() {
    local validation_rc="$1"
    local before_state="$2"
    local after_state="$3"
    local before="$TMP_DIR/before-$validation_rc-$RANDOM"
    printf '%s' "$before_state" > "$before"
    bash -c '
        set -u
        source "$1/scripts/lib/workflows.sh" 2>/dev/null
        AFTER_STATE="$3"
        snapshot_tangle_worktree_state() { printf "%s" "$AFTER_STATE"; }
        if tangle_should_attempt_contextual_review "$4" "$2"; then
            echo yes
        else
            echo no
        fi
    ' _ "$PROJECT_ROOT" "$before" "$after_state" "$validation_rc"
}

test_case "successful initial validation keeps the existing review path"
out=$(run_decision 0 "same" "same")
[[ "$out" == "yes" ]] && test_pass || test_fail "expected yes, got '$out'"

test_case "failed validation without worktree progress still fails fast"
out=$(run_decision 1 "same" "same")
[[ "$out" == "no" ]] && test_pass || test_fail "expected no, got '$out'"

test_case "failed validation with worktree progress enters review recovery"
out=$(run_decision 1 "before" "after")
[[ "$out" == "yes" ]] && test_pass || test_fail "expected yes, got '$out'"

test_case "failed validation detects further edits to an already dirty path"
dirty_repo="$TMP_DIR/dirty-repo"
mkdir -p "$dirty_repo"
git -C "$dirty_repo" init -q
git -C "$dirty_repo" config user.email test@example.com
git -C "$dirty_repo" config user.name "Octopus Test"
printf '%s
' clean > "$dirty_repo/tracked.txt"
git -C "$dirty_repo" add tracked.txt
git -C "$dirty_repo" commit -qm baseline
printf '%s
' dirty-before > "$dirty_repo/tracked.txt"
before_state="$TMP_DIR/dirty-before-state.txt"
out=$(bash -c '
    set -u
    export PROJECT_ROOT="$2"
    source "$1/scripts/lib/testing.sh" 2>/dev/null
    source "$1/scripts/lib/workflows.sh" 2>/dev/null
    snapshot_tangle_worktree_state > "$3"
    printf "%s
" dirty-after > "$2/tracked.txt"
    if tangle_should_attempt_contextual_review 1 "$3"; then
        echo yes
    else
        echo no
    fi
' _ "$PROJECT_ROOT" "$dirty_repo" "$before_state")
[[ "$out" == "yes" ]] && test_pass || test_fail "expected already-dirty edit to enter recovery, got '$out'"

test_case "failed initial validation can recover after one correction round"
out=$(bash -c '
    set -u
    log() { :; }
    octo_event_emit() { :; }
    write_agent_status() { :; }
    record_agents_batch_complete() { :; }
    ink_deliver() { :; }
    run_agent_sync() { :; }
    octopus_agent_override() { echo codex; }
    source "$1/scripts/lib/workflows.sh" 2>/dev/null

    COUNT_FILE="$RESULTS_DIR/recovery-count"
    echo 0 > "$COUNT_FILE"

    tangle_build_develop_review_context() { echo "$RESULTS_DIR/context-$7.md"; }
    tangle_run_context_code_review() {
        TANGLE_REVIEW_FINDINGS_FILE="$RESULTS_DIR/findings-$3.json"
        echo "{\"findings\":[]}" > "$TANGLE_REVIEW_FINDINGS_FILE"
        return 0
    }
    tangle_review_blocking_count() {
        local idx
        idx=$(cat "$COUNT_FILE")
        if [[ "$idx" -eq 0 ]]; then
            echo 1
            echo 1 > "$COUNT_FILE"
        else
            echo 0
        fi
    }
    tangle_findings_signature() { echo "sig-$(cat "$COUNT_FILE")"; }
    tangle_validation_signature() { echo "vsig-$(cat "$COUNT_FILE")"; }
    tangle_apply_review_corrections() {
        TANGLE_CORRECTION_STATUS=done
        TANGLE_CORRECTION_CHANGED=1
        TANGLE_CORRECTION_CONTAMINATION=""
        TANGLE_CORRECTION_FILE="$RESULTS_DIR/correction.md"
        echo "## Status: SUCCESS" > "$TANGLE_CORRECTION_FILE"
        return 0
    }
    validate_tangle_results() { return 0; }

    rc=0
    tangle_contextual_review_gate tg prompt ctx subtasks \
        "$RESULTS_DIR/validation.md" "$RESULTS_DIR/wt.txt" 1 codex || rc=$?
    echo "$rc"
' _ "$PROJECT_ROOT")
[[ "$out" == "0" ]] && test_pass || test_fail "expected recovery rc=0, got '$out'"

test_summary
