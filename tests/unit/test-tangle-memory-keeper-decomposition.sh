#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOWS="$PROJECT_ROOT/scripts/lib/workflows.sh"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "tangle Memory Keeper decomposition regression"
export OCTOPUS_TANGLE_CODE_REVIEW=false
source "$WORKFLOWS"
CYAN=""; GREEN=""; MAGENTA=""; NC=""; TMUX_MODE=false; DRY_RUN=false; SUPPORTS_PARALLEL_FILE_SAFETY=false
TEST_TMP_DIR="${TEST_TMP_DIR:-/tmp/octopus-tests-$$}"
RESULTS_DIR="$TEST_TMP_DIR/memory-keeper"
LOGS_DIR="$RESULTS_DIR/logs"
WORKSPACE_DIR="$RESULTS_DIR/workspace"
rm -rf "$RESULTS_DIR"
mkdir -p "$WORKSPACE_DIR/.octo/agents" "$WORKSPACE_DIR/apps/web/src" "$WORKSPACE_DIR/apps/server/src" "$WORKSPACE_DIR/apps/server/data" "$WORKSPACE_DIR/docs"
touch "$WORKSPACE_DIR/package.json" "$WORKSPACE_DIR/.env.example" "$WORKSPACE_DIR/.gitignore" "$WORKSPACE_DIR/README.md" \
      "$WORKSPACE_DIR/apps/web/package.json" "$WORKSPACE_DIR/apps/web/src/main.jsx" "$WORKSPACE_DIR/apps/web/src/styles.css" "$WORKSPACE_DIR/apps/web/index.html" \
      "$WORKSPACE_DIR/apps/server/package.json" "$WORKSPACE_DIR/apps/server/src/index.js" "$WORKSPACE_DIR/docs/PRODUCT.md"
git -C "$WORKSPACE_DIR" init -q
git -C "$WORKSPACE_DIR" config user.email test@example.invalid
git -C "$WORKSPACE_DIR" config user.name test
git -C "$WORKSPACE_DIR" add .
git -C "$WORKSPACE_DIR" commit -qm baseline
trap 'rm -rf "$TEST_TMP_DIR"' EXIT INT TERM
PROJECT_ROOT="$WORKSPACE_DIR"
VALIDATION_CALLED=false
log(){ :; }
octopus_phase_banner(){ :; }
display_workflow_cost_estimate(){ return 0; }
reset_provider_lockouts(){ :; }
design_review_ceremony(){ :; }
fleet_dispatch_begin(){ :; }
fleet_dispatch_end(){ :; }
run_agent_sync(){
cat <<'EOF'
1. [CODING] Baseline contracts and test scaffolding — Files: package.json, .env.example, .gitignore, README.md, apps/web/package.json, apps/server/package.json, docs/PRODUCT.md — Task: Audit existing scaffold, lock npm workspace layout (apps/web + apps/server), add repository scripts (test, build, check, lint), define documented API contract section, deterministic synthetic fixtures, and confirm runtime files are gitignored under apps/server/data.
2. [CODING] Server foundation, invitation, consent, prompts, recording, and memory-card — Files: apps/server/src/index.js, apps/server/data/ — Task: Implement HTTP server with health/readiness, JSON error envelope, MIME allowlist, upload limits, MediaStorage interface with local filesystem implementation, file-backed persistence for FamilySpace/Invitation/ConsentRecord/StoryPrompt/Recording/MemoryCard, invitation lifecycle, versioned consent, one-prompt-at-a-time gating, deterministic next-topic suggestion, multipart upload with validation, playback retrieval, deterministic memory-card generation behind interface, idempotent deletion with safe-repeat semantics, and invalid-transition guard tests.
3. [CODING] Web application flow — Files: apps/web/src/main.jsx, apps/web/src/styles.css, apps/web/index.html, apps/web/package.json — Task: Build mobile-first accessible inviter→storyteller→review flow with API client, state machine, MediaRecorder with pause/resume/discard/save, upload progress/retry, unsupported-browser fallback, playback, deletion confirmation, reduced-motion behavior, and keyboard-visible focus.
4. [REASONING] Quality validation and handoff evidence — Task: Run unit, integration, and browser tests (happy path + deletion + unsupported-recording + failed-upload recovery), execute npm test / npm run check / production web build, verify zero external services or secrets, confirm git status is clean outside runtime path, and produce final acceptance checklist with architecture summary, changed components, artifact paths, and documented limitations.
EOF
}
spawn_agent_capture_pid(){
  local task_id="$3"
  printf '%s\n' "$2" > "$RESULTS_DIR/${task_id}.prompt"
  printf '0\n' > "$WORKSPACE_DIR/.octo/agents/${task_id}.done"
  printf '%s\n' "$$"
}
validate_tangle_results(){ VALIDATION_CALLED=true; }

tangle_develop "Run the approved Memory Keeper development plan." > "$RESULTS_DIR/run.out" 2>&1

test_case "Memory Keeper residual overlap no longer aborts before dispatch"
if grep -q "Consolidated subtasks:" "$RESULTS_DIR/run.out" && ! grep -q "Unsafe parallel decomposition after retry" "$RESULTS_DIR/run.out"; then test_pass; else cat "$RESULTS_DIR/run.out"; test_fail "run still aborted on residual overlap"; fi

test_case "Memory Keeper repair dispatches exactly three subtasks"
count=$(find "$RESULTS_DIR" -maxdepth 1 -name 'tangle-*.prompt' | wc -l | tr -d ' ')
if [[ "$count" -eq 3 ]]; then test_pass; else find "$RESULTS_DIR" -maxdepth 1 -name 'tangle-*.prompt' -print; test_fail "expected 3 dispatched subtasks, got $count"; fi

test_case "Memory Keeper baseline and web scopes are merged into one coding prompt"
if grep -l "Audit existing scaffold" "$RESULTS_DIR"/tangle-*.prompt | xargs grep -l "Build mobile-first accessible" >/dev/null 2>&1; then test_pass; else test_fail "baseline and web work were not merged into one worker"; fi

test_case "Memory Keeper server task remains independent"
server_count=$(grep -l "Implement HTTP server" "$RESULTS_DIR"/tangle-*.prompt | wc -l | tr -d ' ')
if [[ "$server_count" -eq 1 ]]; then test_pass; else test_fail "server task was not preserved as one independent worker"; fi

test_case "Memory Keeper reasoning task remains independent"
reason_count=$(grep -l "Quality validation and handoff evidence" "$RESULTS_DIR"/tangle-*.prompt | wc -l | tr -d ' ')
if [[ "$reason_count" -eq 1 ]] && [[ "$VALIDATION_CALLED" == true ]]; then test_pass; else test_fail "reasoning task or validation gate was not preserved"; fi

test_summary
