#!/usr/bin/env bash
# Static tests for tangle contextual review/correction loop wiring.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "tangle contextual review loop"

WORKFLOWS="$PROJECT_ROOT/scripts/lib/workflows.sh"
HELP="$PROJECT_ROOT/scripts/lib/usage-help.sh"

# shellcheck disable=SC1090
source "$WORKFLOWS"
log() { :; }

assert_contains() {
    local file="$1"
    local pattern="$2"
    local label="$3"
    test_case "$label"
    if grep -q "$pattern" "$file"; then
        test_pass
    else
        test_fail "missing pattern: $pattern"
    fi
}

make_test_dir() {
    local dir="$TEST_TMP_DIR/$1"
    rm -rf "$dir"
    mkdir -p "$dir"
    printf '%s\n' "$dir"
}

test_case "review warning does not fabricate an actionable blocker"
warning_only="$TEST_TMP_DIR/review-warning-only.json"
printf '%s\n' '{"findings":[],"warning":"Round 1 was partial"}' > "$warning_only"
if [[ "$(tangle_review_blocking_count "$warning_only")" == "0" ]] &&
   [[ "$(tangle_review_warning_text "$warning_only")" == "Round 1 was partial" ]]; then
    test_pass
else
    test_fail "warning-only review must remain blocking through review_rc without becoming severity=normal"
fi

test_case "review warning preserves the count of real actionable blockers"
warning_with_blocker="$TEST_TMP_DIR/review-warning-with-blocker.json"
printf '%s\n' '{"findings":[{"severity":"normal","title":"real blocker"}],"warning":"Round 1 was partial"}' > "$warning_with_blocker"
if [[ "$(tangle_review_blocking_count "$warning_with_blocker")" == "1" ]]; then
    test_pass
else
    test_fail "warning must not alter the number of severity=normal findings"
fi

test_case "schema-invalid review findings remain fail-closed"
malformed_findings="$TEST_TMP_DIR/review-malformed.json"
missing_findings="$TEST_TMP_DIR/review-missing.json"
null_findings="$TEST_TMP_DIR/review-null.json"
non_object_findings="$TEST_TMP_DIR/review-non-object.json"
printf '%s\n' '{"findings":[' > "$malformed_findings"
printf '%s\n' '{}' > "$missing_findings"
printf '%s\n' '{"findings":null}' > "$null_findings"
printf '%s\n' '{"findings":["not-an-object"]}' > "$non_object_findings"
if [[ "$(tangle_review_blocking_count "$TEST_TMP_DIR/review-absent.json")" == "1" ]] &&
   [[ "$(tangle_review_blocking_count "$malformed_findings")" == "1" ]] &&
   [[ "$(tangle_review_blocking_count "$missing_findings")" == "1" ]] &&
   [[ "$(tangle_review_blocking_count "$null_findings")" == "1" ]] &&
   [[ "$(tangle_review_blocking_count "$non_object_findings")" == "1" ]]; then
    test_pass
else
    test_fail "invalid review schemas must retain one blocking failure"
fi

run_warning_review_gate() {
    local case_name="$1"
    local initial_findings="$2"
    local initial_rc="$3"
    local recovery_findings="$4"
    local recovery_rc="$5"
    local case_dir="$TEST_TMP_DIR/review-gate-$case_name"
    rm -rf "$case_dir"
    mkdir -p "$case_dir"

    bash -c '
        set -u
        project_root="$1"
        case_dir="$2"
        initial_findings="$3"
        initial_rc="$4"
        recovery_findings="$5"
        recovery_rc="$6"
        export RESULTS_DIR="$case_dir/results"
        mkdir -p "$RESULTS_DIR"

        initial_file="$case_dir/initial.json"
        recovery_file="$case_dir/recovery.json"
        review_calls_file="$case_dir/review-calls"
        correction_calls_file="$case_dir/correction-calls"
        validation_file="$case_dir/validation.md"
        printf "%s\n" "$initial_findings" > "$initial_file"
        printf "%s\n" "$recovery_findings" > "$recovery_file"
        printf "0" > "$review_calls_file"
        printf "0" > "$correction_calls_file"
        : > "$validation_file"

        source "$project_root/scripts/lib/workflows.sh" 2>/dev/null
        log() { :; }
        tangle_build_develop_review_context() {
            printf "%s\n" "$case_dir/context-$7.md"
        }
        tangle_run_context_code_review() {
            local calls rc
            calls=$(<"$review_calls_file")
            if [[ "$calls" -eq 0 ]]; then
                TANGLE_REVIEW_FINDINGS_FILE="$initial_file"
                rc="$initial_rc"
            else
                TANGLE_REVIEW_FINDINGS_FILE="$recovery_file"
                rc="$recovery_rc"
            fi
            printf "%s" "$((calls + 1))" > "$review_calls_file"
            return "$rc"
        }
        tangle_apply_review_corrections() {
            local calls
            calls=$(<"$correction_calls_file")
            printf "%s" "$((calls + 1))" > "$correction_calls_file"
            TANGLE_CORRECTION_STATUS="completed"
            TANGLE_CORRECTION_CHANGED=1
            TANGLE_CORRECTION_CONTAMINATION=""
            TANGLE_CORRECTION_FILE="$case_dir/correction.md"
            return 0
        }
        validate_tangle_results() { return 0; }

        rc=0
        OCTOPUS_TANGLE_REVIEW_CORRECTION_MODE=bounded \
        OCTOPUS_TANGLE_REVIEW_CORRECTION_ROUNDS=1 \
            tangle_contextual_review_gate \
                test "prompt" "context" "subtasks" \
                "$validation_file" "$case_dir/worktree-before" 0 codex || rc=$?

        printf "rc=%s corrections=%s reviews=%s\n" \
            "$rc" "$(<"$correction_calls_file")" "$(<"$review_calls_file")"
    ' _ "$PROJECT_ROOT" "$case_dir" "$initial_findings" "$initial_rc" \
        "$recovery_findings" "$recovery_rc"
}

test_case "warning-only review is fatal without a correction call"
out=$(run_warning_review_gate \
    warning-only \
    '{"findings":[],"warning":"Round 1 was partial"}' 1 \
    '{"findings":[]}' 0)
if [[ "$out" == "rc=1 corrections=0 reviews=1" ]]; then
    test_pass
else
    test_fail "warning-only review entered correction or lost fatal status: $out"
fi

test_case "warning with a real blocker can recover after one bounded correction"
out=$(run_warning_review_gate \
    warning-with-blocker \
    '{"findings":[{"severity":"normal","title":"real blocker","file":"src/app.sh","line":1}],"warning":"Round 1 was partial"}' 1 \
    '{"findings":[]}' 0)
if [[ "$out" == "rc=0 corrections=1 reviews=2" ]]; then
    test_pass
else
    test_fail "actionable warning did not complete one bounded recovery: $out"
fi

test_case "missing findings array is fatal without a correction call"
out=$(run_warning_review_gate \
    missing-findings \
    '{}' 0 \
    '{"findings":[]}' 0)
if [[ "$out" == "rc=1 corrections=0 reviews=1" ]]; then
    test_pass
else
    test_fail "missing findings array entered correction or passed: $out"
fi

test_case "truncated findings are fatal without a correction call"
out=$(run_warning_review_gate \
    truncated-findings \
    '{"findings":[' 0 \
    '{"findings":[]}' 0)
if [[ "$out" == "rc=1 corrections=0 reviews=1" ]]; then
    test_pass
else
    test_fail "truncated findings entered correction or passed: $out"
fi

assert_contains "$WORKFLOWS" "tangle_build_develop_review_context" "tangle builds review context"
assert_contains "$WORKFLOWS" "tangle_run_context_code_review" "tangle runs contextual code review"
assert_contains "$WORKFLOWS" "contextFile" "review profile passes contextFile"
assert_contains "$WORKFLOWS" ".claude-octopus/results" "review context is stored inside workspace"
assert_contains "$WORKFLOWS" "plan-conformance" "review focus includes plan conformance"
assert_contains "$WORKFLOWS" "tangle_apply_review_corrections" "tangle applies review corrections"
assert_contains "$WORKFLOWS" "OCTOPUS_TANGLE_REVIEW_CORRECTION_MODE" "correction loop supports explicit bounded mode"
assert_contains "$WORKFLOWS" "OCTOPUS_TANGLE_CORRECTION_STALL_WINDOW" "correction loop uses stall watchdog"
assert_contains "$WORKFLOWS" "OCTOPUS_TANGLE_DEADLINE:-0" "initial tangle deadline defaults to no absolute timeout"
assert_contains "$WORKFLOWS" "decompose_prompt" "decomposition prompt is present"
assert_contains "$WORKFLOWS" '"$decompose_prompt" 0' "decomposition runs without absolute timeout"
assert_contains "$WORKFLOWS" "_tangle_max_wait" "initial tangle deadline is optional"
assert_contains "$WORKFLOWS" "failed but left partial writes" "partial writes continue to validation/review"
assert_contains "$WORKFLOWS" 'run_agent_sync "$correction_agent" "$correction_prompt" 0' "corrections run without absolute timeout"
assert_contains "$WORKFLOWS" "OCTOPUS_TANGLE_CODE_REVIEW" "code review gate is toggleable"
assert_contains "$WORKFLOWS" "Contextual code review warning" "review warnings are blocking"
assert_contains "$WORKFLOWS" "No changes found to review" "legacy no-diff message is detected"
assert_contains "$WORKFLOWS" "with no actionable blockers" "non-zero review without actionable blockers is blocking"
assert_contains "$WORKFLOWS" "Skipping ink/deliver because tangle validation gate returned non-zero" "ink is skipped when validation fails"
assert_contains "$HELP" "Contextual code review" "develop help documents contextual review"
assert_contains "$HELP" "OCTOPUS_TANGLE_REVIEW_CORRECTION_MODE" "develop help documents bounded mode"
assert_contains "$HELP" "OCTOPUS_TANGLE_CORRECTION_STALL_WINDOW" "develop help documents stall window"
assert_contains "$WORKFLOWS" "OCTOPUS_INK_REVIEW_TIMEOUT:-0" "ink review has no wall timeout by default"

test_case "generated review context stays inside the workspace"
workspace=$(make_test_dir workspace-context)
if context_file=$(PROJECT_ROOT="$workspace" tangle_build_develop_review_context \
        "test" "prompt" "context" "subtasks" "/nonexistent-validation" \
        "/nonexistent-snapshot" "initial") &&
   workspace_physical=$(cd "$workspace" && pwd -P) &&
   context_dir_physical=$(cd "$(dirname "$context_file")" && pwd -P) &&
   [[ -f "$context_file" ]] &&
   [[ "$context_dir_physical" == "$workspace_physical/.claude-octopus/results" ]]; then
    test_pass
else
    test_fail "generated context must exist under the physical workspace root"
fi

test_case "logical workspace symlink returns a physical context path"
workspace=$(make_test_dir workspace-physical)
workspace_link="$TEST_TMP_DIR/workspace-logical-link"
rm -f "$workspace_link"
ln -s "$workspace" "$workspace_link"
if context_file=$(PROJECT_ROOT="$workspace_link" tangle_build_develop_review_context \
        "test" "prompt" "context" "subtasks" "/nonexistent-validation" \
        "/nonexistent-snapshot" "initial") &&
   workspace_physical=$(cd "$workspace" && pwd -P) &&
   [[ "$context_file" == "$workspace_physical/.claude-octopus/results/develop-review-context-test-initial.md" ]] &&
   [[ -f "$context_file" ]]; then
    test_pass
else
    test_fail "returned context path must use the validated physical workspace"
fi

test_case "symlinked review results directory is rejected"
workspace=$(make_test_dir workspace-symlink)
outside=$(make_test_dir outside-symlink)
mkdir -p "$workspace/.claude-octopus"
ln -s "$outside" "$workspace/.claude-octopus/results"
if ! PROJECT_ROOT="$workspace" tangle_build_develop_review_context \
        "test" "prompt" "context" "subtasks" "/nonexistent-validation" \
        "/nonexistent-snapshot" "initial" >/dev/null 2>&1 &&
   [[ -z "$(find "$outside" -mindepth 1 -print -quit)" ]]; then
    test_pass
else
    test_fail "symlinked results directory must fail without writing outside the workspace"
fi

test_case "external results override cannot redirect review context"
workspace=$(make_test_dir workspace-override)
outside=$(make_test_dir outside-override)
if context_file=$(PROJECT_ROOT="$workspace" RESULTS_DIR="$outside" \
        tangle_build_develop_review_context "test" "prompt" "context" "subtasks" \
        "/nonexistent-validation" "/nonexistent-snapshot" "initial") &&
   workspace_physical=$(cd "$workspace" && pwd -P) &&
   context_dir_physical=$(cd "$(dirname "$context_file")" && pwd -P) &&
   [[ -f "$context_file" ]] &&
   [[ "$context_dir_physical" == "$workspace_physical/.claude-octopus/results" ]] &&
   [[ -z "$(find "$outside" -mindepth 1 -print -quit)" ]]; then
    test_pass
else
    test_fail "review context must ignore external RESULTS_DIR paths"
fi

test_case "review context artifacts do not pollute git status"
workspace=$(make_test_dir workspace-git-clean)
git -C "$workspace" init -q
if context_file=$(PROJECT_ROOT="$workspace" tangle_build_develop_review_context \
        "test" "prompt" "context" "subtasks" "/nonexistent-validation" \
        "/nonexistent-snapshot" "initial") &&
   [[ -f "$context_file" ]] &&
   [[ -z "$(git -C "$workspace" status --porcelain)" ]]; then
    test_pass
else
    test_fail "workspace-local review artifacts must remain git-ignored"
fi

test_case "existing repository-managed ignore file is preserved"
workspace=$(make_test_dir workspace-existing-ignore)
git -C "$workspace" init -q
mkdir -p "$workspace/.claude-octopus/results"
printf 'develop-review-context-*.md\n.develop-review-context.*\n' > "$workspace/.claude-octopus/results/.gitignore"
git -C "$workspace" add -f .claude-octopus/results/.gitignore
ignore_before=$(git -C "$workspace" hash-object .claude-octopus/results/.gitignore)
if context_file=$(PROJECT_ROOT="$workspace" tangle_build_develop_review_context \
        "test" "prompt" "context" "subtasks" "/nonexistent-validation" \
        "/nonexistent-snapshot" "initial") &&
   ignore_after=$(git -C "$workspace" hash-object .claude-octopus/results/.gitignore) &&
   [[ "$ignore_before" == "$ignore_after" ]] &&
   git -C "$workspace" diff --quiet -- .claude-octopus/results/.gitignore &&
   [[ -f "$context_file" ]]; then
    test_pass
else
    test_fail "existing repository-managed ignore rules must remain unchanged"
fi

test_case "repository ignore rules must cover scratch artifacts"
workspace=$(make_test_dir workspace-incomplete-ignore)
git -C "$workspace" init -q
mkdir -p "$workspace/.claude-octopus/results"
printf 'develop-review-context-*.md\n' > "$workspace/.claude-octopus/results/.gitignore"
if ! PROJECT_ROOT="$workspace" tangle_build_develop_review_context \
        "test" "prompt" "context" "subtasks" "/nonexistent-validation" \
        "/nonexistent-snapshot" "initial" >/dev/null 2>&1 &&
   [[ -z "$(find "$workspace/.claude-octopus/results" -type f ! -name .gitignore -print -quit)" ]]; then
    test_pass
else
    test_fail "generation must fail cleanly before creating an unignored scratch file"
fi

test_case "pre-existing context-file symlink is rejected"
workspace=$(make_test_dir workspace-file-symlink)
outside="$TEST_TMP_DIR/outside-file-target"
rm -f "$outside"
printf 'sentinel\n' > "$outside"
mkdir -p "$workspace/.claude-octopus/results"
ln -s "$outside" "$workspace/.claude-octopus/results/develop-review-context-test-initial.md"
if ! PROJECT_ROOT="$workspace" tangle_build_develop_review_context \
        "test" "prompt" "context" "subtasks" "/nonexistent-validation" \
        "/nonexistent-snapshot" "initial" >/dev/null 2>&1 &&
   [[ "$(cat "$outside")" == "sentinel" ]]; then
    test_pass
else
    test_fail "context-file symlinks must fail without modifying their targets"
fi

test_case "unsafe context labels are rejected"
workspace=$(make_test_dir workspace-unsafe-label)
if ! PROJECT_ROOT="$workspace" tangle_build_develop_review_context \
        "../escape" "prompt" "context" "subtasks" "/nonexistent-validation" \
        "/nonexistent-snapshot" "initial" >/dev/null 2>&1 &&
   [[ ! -e "$workspace/.claude-octopus" ]]; then
    test_pass
else
    test_fail "unsafe labels must fail before creating review artifacts"
fi

REVIEW="$PROJECT_ROOT/scripts/lib/review.sh"
assert_contains "$REVIEW" "\"warning\":\"No changes found to review\"" "review no-diff writes warning"
assert_contains "$REVIEW" "return 1" "review no-diff returns non-zero"

QUALITY="$PROJECT_ROOT/scripts/lib/quality.sh"
assert_contains "$QUALITY" "OCTOPUS_DESIGN_REVIEW_TIMEOUT:-0" "design review uses no wall timeout by default"
assert_contains "$QUALITY" "_design_timeout_label" "design review reports effective timeout label"

HEARTBEAT="$PROJECT_ROOT/scripts/lib/heartbeat.sh"
assert_contains "$HEARTBEAT" "timeout_secs=0 means no absolute timeout" "timeout zero disables absolute timeout"
SPAWN="$PROJECT_ROOT/scripts/lib/spawn.sh"
assert_contains "$SPAWN" "TIMEOUT=0 remains" "spawn respects TIMEOUT=0"
assert_contains "$SPAWN" 'octopus_effective_agent_timeout "${TIMEOUT:-0}"' "all providers use the supervised workflow timeout"

TESTING="$PROJECT_ROOT/scripts/lib/testing.sh"
assert_contains "$TESTING" "OCTOPUS_TANGLE_VALIDATION_CORRECTION_FILE" "post-correction validation overlay is wired"
assert_contains "$TESTING" "Static Subtask Rate Before Correction Overlay" "post-correction validation reports static subtask rate"
assert_contains "$WORKFLOWS" "OCTOPUS_TANGLE_VALIDATION_CORRECTION_CHANGED" "correction loop passes validation overlay context"
assert_contains "$WORKFLOWS" "OCTOPUS_TANGLE_CONVERGENCE_NO_PROGRESS_ROUNDS" "correction loop has convergence guard"
assert_contains "$WORKFLOWS" "tangle_review_blocking_count" "review blocking count helper exists"
assert_contains "$WORKFLOWS" "fail closed" "malformed review findings fail closed"
assert_contains "$WORKFLOWS" "OCTOPUS_UNBOUNDED_EXECUTION_SUPERVISED" "unbounded agent calls document external supervision"
assert_contains "$WORKFLOWS" "stat -f '%z'" "correction progress size uses BSD stat fallback"
assert_contains "$WORKFLOWS" "defaulting to 1 round" "bounded correction mode has implicit cap"
assert_contains "$WORKFLOWS" "tangle_process_is_active_non_zombie" "tangle watcher treats zombies as terminal"
assert_contains "$WORKFLOWS" "exited or became zombie without completion marker" "tangle watcher logs zombie missing-marker grace"
assert_contains "$WORKFLOWS" "OCTOPUS_TANGLE_CONVERGENCE_VALIDATION_PROGRESS" "convergence guard does not treat validation rerenders as progress by default"
assert_contains "$WORKFLOWS" "validation signature changed but blocker best did not improve" "convergence guard logs ignored validation-only movement"
assert_contains "$WORKFLOWS" "interrupted-partial" "correction loop stops on interrupted partial writes"
assert_contains "$WORKFLOWS" "rc=" "interrupted correction logs provider exit code"

test_summary
