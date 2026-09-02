#!/usr/bin/env bash
# Regression checks for /octo:develop parallel write-scope safety.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOWS="$PROJECT_ROOT/scripts/lib/workflows.sh"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "tangle write-scope safety"

# These tests exercise tangle dispatch/validation behavior, not contextual review.
export OCTOPUS_TANGLE_CODE_REVIEW=false

# shellcheck source=/dev/null
source "$WORKFLOWS"

CYAN=""
GREEN=""
MAGENTA=""
NC=""
TMUX_MODE=false
DRY_RUN=false
SUPPORTS_PARALLEL_FILE_SAFETY=false
TEST_TMP_DIR="${TEST_TMP_DIR:-/tmp/octopus-tests-$$}"
RESULTS_DIR="$TEST_TMP_DIR/tangle-write-scope-safety"
LOGS_DIR="$RESULTS_DIR/logs"
WORKSPACE_DIR="$RESULTS_DIR/workspace"
rm -rf "$RESULTS_DIR"
mkdir -p "$WORKSPACE_DIR/.octo/agents"
trap 'rm -rf "$TEST_TMP_DIR"' EXIT INT TERM

DIRECT_PROMPT=""
DIRECT_TASK_ID=""
PARALLEL_SPAWNED=false
VALIDATION_CALLED=false
TANGLE_STATUS=0

log() { :; }
octopus_phase_banner() { :; }
display_workflow_cost_estimate() { return 0; }
reset_provider_lockouts() { :; }
design_review_ceremony() { :; }
fleet_dispatch_begin() { :; }
fleet_dispatch_end() { :; }
run_agent_sync() {
    cat <<'EOF'
1. [CODING] Add the reference prefix. Files: src/lib/templates/NA02_REQUEST_REPORT.ts
2. [CODING] Add legal wording to the same template. Files: src/lib/templates/NA02_REQUEST_REPORT.ts, src/lib/legal/legalReferenceCatalog.ts
EOF
}
spawn_agent_capture_pid() {
    local task_id="$3"
    touch "$RESULTS_DIR/parallel.spawned"
    printf '%s\n' "$2" > "$RESULTS_DIR/${task_id}.prompt"
    mkdir -p "$WORKSPACE_DIR/.octo/agents"
    printf '0\n' > "$WORKSPACE_DIR/.octo/agents/${task_id}.done"
    printf '%s\n' "$$"
}
spawn_agent() {
    DIRECT_PROMPT="$2"
    DIRECT_TASK_ID="$3"
}
validate_tangle_results() {
    VALIDATION_CALLED=true
}

test_case "directory write scopes overlap contained files"
if tangle_scopes_overlap "src/lib/templates/" "src/lib/templates/NA02_REQUEST_REPORT.ts" && \
   ! tangle_scopes_overlap "src/lib/templates/" "src/lib/legal/legalReferenceCatalog.ts"; then
    test_pass
else
    test_fail "directory/file overlap detection is incorrect"
fi

test_case "write scope extraction reads only Files clause"
scopes=$(tangle_extract_write_scopes "[CODING] Update docs after reading src/context.ts. Files: README.md, docs/setup.md")
if [[ "$scopes" == *"README.md"* ]] && \
   [[ "$scopes" == *"docs/setup.md"* ]] && \
   [[ "$scopes" != *"src/context.ts"* ]]; then
    test_pass
else
    test_fail "write scope extraction did not isolate Files clause; got: $scopes"
fi

test_case "write scope extraction requires explicit Files clause"
scopes=$(tangle_extract_write_scopes "[CODING] Update src/context.ts after reading README.md")
if [[ -z "$scopes" ]]; then
    test_pass
else
    test_fail "write scope extraction parsed arbitrary prose without Files clause: $scopes"
fi

test_case "write scope extraction accepts root-level filenames"
scopes=$(tangle_extract_write_scopes "[CODING] Update build files. Files: Makefile, Dockerfile, package.json")
if [[ "$scopes" == *"Makefile"* ]] && \
   [[ "$scopes" == *"Dockerfile"* ]] && \
   [[ "$scopes" == *"package.json"* ]]; then
    test_pass
else
    test_fail "write scope extraction rejected root-level filenames; got: $scopes"
fi

test_case "write scope extraction accepts balanced Markdown wrappers"
scopes=$(tangle_extract_write_scopes '[CODING] Update docs. Files: `README.md`, "docs/setup.md"')
if [[ "$scopes" == *"README.md"* ]] && [[ "$scopes" == *"docs/setup.md"* ]]; then
    test_pass
else
    test_fail "balanced scope wrappers were not removed safely; got: $scopes"
fi

test_case "known scope lookup falls back to pwd when PROJECT_ROOT is invalid"
real_project_root="$PROJECT_ROOT"
if (
    cd "$real_project_root"
    PROJECT_ROOT="$TEST_TMP_DIR/missing-project-root"
    tangle_scope_is_known_or_explicit_new_file "scripts/lib/workflows.sh"
); then
    test_pass
else
    test_fail "known scope lookup did not fall back when PROJECT_ROOT was invalid"
fi

test_case "repo context resolution falls back to pwd when PROJECT_ROOT is invalid"
resolved_scopes=$(
    cd "$real_project_root"
    PROJECT_ROOT="$TEST_TMP_DIR/missing-project-root" \
        tangle_resolve_repo_context_files "Update workflow safety. Files: scripts/lib/workflows.sh"
)
if [[ "$resolved_scopes" == *"scripts/lib/workflows.sh"* ]]; then
    test_pass
else
    test_fail "repo context resolution did not fall back when PROJECT_ROOT was invalid: $resolved_scopes"
fi

test_case "existing non-git PROJECT_ROOT does not resolve scopes from unrelated pwd repo"
resolved_scopes=$(
    cd "$real_project_root"
    mkdir -p "$TEST_TMP_DIR/not-a-repo"
    PROJECT_ROOT="$TEST_TMP_DIR/not-a-repo" \
        tangle_resolve_repo_context_files "Update workflow safety. Files: scripts/lib/workflows.sh"
)
if [[ -z "$resolved_scopes" ]]; then
    test_pass
else
    test_fail "repo context resolution used cwd repo despite explicit non-git PROJECT_ROOT: $resolved_scopes"
fi

test_case "known scope lookup honors existing non-git PROJECT_ROOT files"
if (
    cd "$real_project_root"
    mkdir -p "$TEST_TMP_DIR/not-a-repo/scripts/lib"
    touch "$TEST_TMP_DIR/not-a-repo/scripts/lib/workflows.sh"
    PROJECT_ROOT="$TEST_TMP_DIR/not-a-repo"
    tangle_scope_is_known_or_explicit_new_file "scripts/lib/workflows.sh"
); then
    test_pass
else
    test_fail "known scope lookup ignored files under explicit non-git PROJECT_ROOT"
fi

original_prompt="Update src/lib/templates/NA02_REQUEST_REPORT.ts and src/lib/legal/legalReferenceCatalog.ts without producing duplicate subject prefixes."

tangle_develop "$original_prompt" >/dev/null && TANGLE_STATUS=0 || TANGLE_STATUS=$?

test_case "repairable overlapping coding scopes are consolidated and dispatched"
if [[ "$TANGLE_STATUS" -eq 0 ]] && [[ -f "$RESULTS_DIR/parallel.spawned" ]]; then
    test_pass
else
    test_fail "repairable overlap did not consolidate into a runnable decomposition"
fi

test_case "overlapping coding tasks are consolidated before worker dispatch"
spawned_prompt_files=$(find "$RESULTS_DIR" -maxdepth 1 -type f -name 'tangle-*.prompt' | sort)
spawned_prompt_count=$(printf '%s\n' "$spawned_prompt_files" | sed '/^$/d' | wc -l | tr -d '[:space:]')
spawned_prompt=""
if [[ "$spawned_prompt_count" -eq 1 ]]; then
    spawned_prompt=$(cat "$spawned_prompt_files")
fi
if [[ "$spawned_prompt_count" -eq 1 ]] && \
   [[ "$spawned_prompt" == *"Add the reference prefix"* ]] && \
   [[ "$spawned_prompt" == *"Add legal wording to the same template"* ]] && \
   [[ "$spawned_prompt" == *"src/lib/templates/NA02_REQUEST_REPORT.ts"* ]] && \
   [[ "$spawned_prompt" == *"src/lib/legal/legalReferenceCatalog.ts"* ]]; then
    test_pass
else
    test_fail "worker dispatch did not receive exactly one consolidated coding prompt"
fi

# Repo-context is resolution/read guidance, not implicit extra write authority.
test_case "Task-only paths cannot become effective write scope"
task_only_subtask="[CODING] Demo — Files: missing/declared.ts — Task: inspect scripts/lib/workflows.sh only"
task_only_effective=$(tangle_effective_write_scopes "$task_only_subtask")
if [[ "$task_only_effective" == "missing/declared.ts" ]] && \
   [[ "$task_only_effective" != *"scripts/lib/workflows.sh"* ]]; then
    test_pass
else
    test_fail "Task prose path leaked into effective write scope: $task_only_effective"
fi

test_case "write scope resolution does not expand domain-keyword heuristics"
heuristic_subtask="[CODING] Demo — Files: missing/commands/execute.js — Task: update only the declared file"
heuristic_effective=$(tangle_effective_write_scopes "$heuristic_subtask")
if [[ "$heuristic_effective" == "missing/commands/execute.js" ]] && \
   [[ "$heuristic_effective" != *"README.md"* ]] && \
   [[ "$heuristic_effective" != *"package.json"* ]]; then
    test_pass
else
    test_fail "heuristic repo context leaked into write scope: $heuristic_effective"
fi

test_case "unsafe declared scopes are dropped before fallback"
unsafe_subtask="[CODING] Demo — Files: .git/hooks/pre-commit — Task: update hook"
unsafe_effective=$(tangle_effective_write_scopes "$unsafe_subtask")
if [[ -z "$unsafe_effective" ]]; then
    test_pass
else
    test_fail "unsafe declared scope survived effective-scope filtering: $unsafe_effective"
fi

test_case "decomposition validation rejects mixed safe and unsafe scopes"
unsafe_decomposition="1. [CODING] Demo — Files: scripts/lib/workflows.sh, .git/hooks/pre-commit — Task: update workflow"
if unsafe_reason=$(tangle_validate_parallel_write_scopes "$unsafe_decomposition"); then
    test_fail "decomposition validation accepted an unsafe declared scope"
elif [[ "$unsafe_reason" == *"unsafe write scope '.git/hooks/pre-commit'"* ]]; then
    test_pass
else
    test_fail "unexpected unsafe-scope rejection reason: $unsafe_reason"
fi

test_case "decomposition validation rejects an absolute scope filtered by normalization"
absolute_decomposition="1. [CODING] Demo — Files: scripts/lib/workflows.sh, /tmp/outside — Task: update workflow"
if absolute_reason=$(tangle_validate_parallel_write_scopes "$absolute_decomposition"); then
    test_fail "decomposition validation accepted an absolute declared scope"
elif [[ "$absolute_reason" == *"unsafe write scope '/tmp/outside'"* ]]; then
    test_pass
else
    test_fail "unexpected absolute-scope rejection reason: $absolute_reason"
fi

test_case "decomposition validation rejects a wildcard scope filtered by normalization"
wildcard_decomposition="1. [CODING] Demo — Files: scripts/lib/workflows.sh, scripts/* — Task: update workflow"
if wildcard_reason=$(tangle_validate_parallel_write_scopes "$wildcard_decomposition"); then
    test_fail "decomposition validation accepted a wildcard declared scope"
elif [[ "$wildcard_reason" == *"unsafe write scope 'scripts/*'"* ]]; then
    test_pass
else
    test_fail "unexpected wildcard-scope rejection reason: $wildcard_reason"
fi

test_case "scope punctuation is validated instead of stripped"
punctuation_bypass=false
for malformed_scope in 'scripts/[ab].sh' 'scripts/{a,b}.sh' 'scripts/(ab).sh' 'scripts/foo"bar.sh'; do
    if tangle_validate_parallel_write_scopes \
        "1. [CODING] Demo — Files: ${malformed_scope} — Task: update workflow" >/dev/null 2>&1; then
        punctuation_bypass=true
        break
    fi
done
if [[ "$punctuation_bypass" == "false" ]]; then
    test_pass
else
    test_fail "malformed scope punctuation was erased before validation: $malformed_scope"
fi

test_case "Files clause requires an exact pre-Task boundary"
boundary_bypass=false
for malformed_line in \
    '1. [CODING] Demo — NoFiles: scripts/lib/workflows.sh — Task: update workflow' \
    '1. [CODING] Demo — No Files: scripts/lib/workflows.sh — Task: update workflow' \
    '1. [CODING] Demo — Profile Files: scripts/lib/workflows.sh — Task: update workflow' \
    '1. [CODING] Demo — Task: discuss Files: scripts/lib/workflows.sh'; do
    if tangle_validate_parallel_write_scopes "$malformed_line" >/dev/null 2>&1; then
        boundary_bypass=true
        break
    fi
done
if [[ "$boundary_bypass" == "false" ]]; then
    test_pass
else
    test_fail "non-clause Files text granted write scope: $malformed_line"
fi

test_case "scope extraction is locale-stable for em-dash separators"
locale_scopes=$(LC_ALL=C tangle_extract_write_scopes \
    '1. [CODING] Demo — Files: scripts/lib/workflows.sh — Task: update workflow')
if [[ "$locale_scopes" == "scripts/lib/workflows.sh" ]]; then
    test_pass
else
    test_fail "LC_ALL=C produced stray scope tokens: $locale_scopes"
fi

test_case "dotted directories and case aliases cannot bypass overlap checks"
if tangle_scopes_overlap '.github' '.github/workflows/test.yml' && \
   tangle_scopes_overlap '.future-config' '.future-config/settings.yml' && \
   tangle_scopes_overlap 'README.md' 'readme.md'; then
    test_pass
else
    test_fail "filesystem aliases were treated as disjoint"
fi

test_case "write scopes cannot traverse repository symlinks"
symlink_repo="$TEST_TMP_DIR/symlink-repo"
symlink_outside="$TEST_TMP_DIR/symlink-outside"
mkdir -p "$symlink_repo/scripts" "$symlink_outside"
git -C "$symlink_repo" init -q
touch "$symlink_repo/scripts/tracked.sh"
git -C "$symlink_repo" add scripts/tracked.sh
ln -s "$symlink_outside" "$symlink_repo/escape"
ln -s "$symlink_repo/.git/hooks" "$symlink_repo/hooks-alias"
symlink_escape_rc=0
symlink_git_rc=0
(
    PROJECT_ROOT="$symlink_repo"
    tangle_validate_parallel_write_scopes \
        '1. [CODING] Demo — Files: escape/newfile — Task: write outside'
) >/dev/null 2>&1 || symlink_escape_rc=$?
(
    PROJECT_ROOT="$symlink_repo"
    tangle_validate_parallel_write_scopes \
        '1. [CODING] Demo — Files: hooks-alias/pre-commit — Task: write a hook'
) >/dev/null 2>&1 || symlink_git_rc=$?
if [[ "$symlink_escape_rc" -ne 0 && "$symlink_git_rc" -ne 0 ]]; then
    test_pass
else
    test_fail "symlink scope escaped validation: outside=$symlink_escape_rc git=$symlink_git_rc"
fi

test_case "ambiguous invented basenames fail closed"
ambiguous_repo="$TEST_TMP_DIR/ambiguous-repo"
mkdir -p "$ambiguous_repo/one" "$ambiguous_repo/two"
git -C "$ambiguous_repo" init -q
touch "$ambiguous_repo/one/SKILL.md" "$ambiguous_repo/two/SKILL.md"
git -C "$ambiguous_repo" add one/SKILL.md two/SKILL.md
ambiguous_rc=0
(
    PROJECT_ROOT="$ambiguous_repo"
    tangle_validate_parallel_write_scopes \
        '1. [CODING] Demo — Files: missing/SKILL.md — Task: update a skill'
) >/dev/null 2>&1 || ambiguous_rc=$?
if [[ "$ambiguous_rc" -ne 0 ]]; then
    test_pass
else
    test_fail "ambiguous scope remained as phantom write authority"
fi

test_case "scope normalization cannot erase or narrow unsafe declarations"
normalization_bypass_failed=false
for unsafe_scope in 'scripts/..' '.' '..' './' '././' '..:123'; do
    normalization_bypass_reason=""
    normalization_bypass_rc=0
    normalization_bypass_reason=$(tangle_validate_parallel_write_scopes \
        "1. [CODING] Demo — Files: scripts/lib/workflows.sh, ${unsafe_scope} — Task: update workflow") || normalization_bypass_rc=$?
    if [[ "$normalization_bypass_rc" -eq 0 || "$normalization_bypass_reason" != *"unsafe write scope"* ]]; then
        normalization_bypass_failed=true
        break
    fi
done
if [[ "$normalization_bypass_failed" == "false" ]]; then
    test_pass
else
    test_fail "unsafe scope was erased or narrowed before validation: ${unsafe_scope} => ${normalization_bypass_rc}:${normalization_bypass_reason}"
fi

test_case "decomposition validation rejects duplicate Files clauses regardless of order"
duplicate_files_unsafe_first="1. [CODING] Demo — Files: /tmp/outside — Task: first Files: scripts/lib/workflows.sh — Task: second"
duplicate_files_unsafe_last="1. [CODING] Demo — Files: scripts/lib/workflows.sh — Task: first Files: /tmp/outside — Task: second"
duplicate_first_reason=""
duplicate_last_reason=""
duplicate_first_rc=0
duplicate_last_rc=0
duplicate_first_reason=$(tangle_validate_parallel_write_scopes "$duplicate_files_unsafe_first") || duplicate_first_rc=$?
duplicate_last_reason=$(tangle_validate_parallel_write_scopes "$duplicate_files_unsafe_last") || duplicate_last_rc=$?
if [[ "$duplicate_first_rc" -ne 0 && "$duplicate_last_rc" -ne 0 ]] &&
   [[ "$duplicate_first_reason" == *"exactly one Files clause"* ]] &&
   [[ "$duplicate_last_reason" == *"exactly one Files clause"* ]]; then
    test_pass
else
    test_fail "duplicate Files clauses were not rejected consistently: first=[$duplicate_first_rc:$duplicate_first_reason] last=[$duplicate_last_rc:$duplicate_last_reason]"
fi

test_case "later malformed declarations take precedence over earlier repairable overlaps"
overlap_before_malformed=$'1. [CODING] First — Files: scripts/lib/workflows.sh — Task: first\n2. [CODING] Second — Files: scripts/lib/workflows.sh — Task: second\n3. [CODING] Malformed — Files: tests/unit/test-tangle-write-scope-safety.sh Files: /tmp/outside — Task: third'
overlap_before_malformed_reason=""
overlap_before_malformed_reason=$(tangle_validate_parallel_write_scopes "$overlap_before_malformed") || true
if [[ "$overlap_before_malformed_reason" == *"coding subtask 3 must contain exactly one Files clause"* ]]; then
    test_pass
else
    test_fail "earlier overlap hid a later malformed declaration: $overlap_before_malformed_reason"
fi

test_case "path aliases cannot bypass overlap detection"
slash_alias_decomposition=$'1. [CODING] First — Files: scripts//lib/workflows.sh — Task: first\n2. [CODING] Second — Files: scripts/lib/workflows.sh — Task: second'
dot_alias_decomposition=$'1. [CODING] First — Files: ././scripts/lib/workflows.sh — Task: first\n2. [CODING] Second — Files: scripts/lib/workflows.sh — Task: second'
slash_alias_rc=0
dot_alias_rc=0
tangle_validate_parallel_write_scopes "$slash_alias_decomposition" >/dev/null || slash_alias_rc=$?
tangle_validate_parallel_write_scopes "$dot_alias_decomposition" >/dev/null || dot_alias_rc=$?
if [[ "$slash_alias_rc" -ne 0 && "$dot_alias_rc" -ne 0 ]]; then
    test_pass
else
    test_fail "equivalent path spellings were treated as disjoint: slash=$slash_alias_rc dot=$dot_alias_rc"
fi

punctuation_alias_rc=0
tangle_validate_parallel_write_scopes $'1. [CODING] First — Files: scripts/lib/workflows.sh. — Task: update workflow\n2. [CODING] Second — Files: scripts/lib/workflows.sh — Task: update workflow tests' >/dev/null 2>&1 || punctuation_alias_rc=$?

test_case "trailing sentence punctuation cannot disguise an overlapping scope"
if [[ "$punctuation_alias_rc" -ne 0 ]]; then
    test_pass
else
    test_fail "trailing punctuation made equivalent scopes appear disjoint"
fi

test_case "write scope resolution permits a unique basename match"
basename_subtask="[CODING] Demo — Files: missing/workflows.sh — Task: update the declared workflow file"
basename_effective=$(tangle_effective_write_scopes "$basename_subtask")
if [[ "$basename_effective" == "scripts/lib/workflows.sh" ]]; then
    test_pass
else
    test_fail "unique basename was not resolved strictly: $basename_effective"
fi

test_case "repo context does not grant write scope beyond Files clause"
scope_prompt=$(build_tangle_subtask_prompt \
    "Update the request report safely." \
    "Update report — Files: src/lib/templates/NA02_REQUEST_REPORT.ts — Task: inspect src/lib/legal/legalReferenceCatalog.ts but do not edit it")
if [[ "$scope_prompt" == *"Files: paths/directories as the exclusive write-scope authority"* ]] && \
   [[ "$scope_prompt" == *"does not grant permission to edit additional files"* ]]; then
    test_pass
else
    test_fail "subtask prompt still treats repository context as implicit write authorization"
fi

test_case "repairable overlap does not spawn direct fallback"
if [[ -z "$DIRECT_TASK_ID" && -z "$DIRECT_PROMPT" ]]; then
    test_pass
else
    test_fail "direct fallback was spawned despite deterministic overlap repair"
fi

test_case "repaired decomposition reaches tangle validation"
if [[ "$VALIDATION_CALLED" == "true" ]]; then
    test_pass
else
    test_fail "validation did not run after deterministic overlap repair"
fi

run_agent_sync() {
    cat <<'EOF'
1. [CODING] First overlap — Files: scripts/lib/workflows.sh — Task: update workflow
2. [CODING] Second overlap — Files: scripts/lib/workflows.sh — Task: update tests
3. [CODING] Later unsafe declaration — Files: tests/unit/test-tangle-write-scope-safety.sh Files: /tmp/outside — Task: update safety tests
EOF
}
rm -f "$RESULTS_DIR/parallel.spawned"
DIRECT_PROMPT=""
DIRECT_TASK_ID=""
unsafe_tangle_rc=0
tangle_develop "$original_prompt" >/dev/null 2>&1 || unsafe_tangle_rc=$?

test_case "later unsafe declarations cannot be laundered through earlier overlap consolidation"
if [[ "$unsafe_tangle_rc" -ne 0 && ! -f "$RESULTS_DIR/parallel.spawned" ]] &&
   [[ -z "$DIRECT_TASK_ID" && -z "$DIRECT_PROMPT" ]]; then
    test_pass
else
    test_fail "unsafe overlapping decomposition reached worker dispatch"
fi

test_summary
