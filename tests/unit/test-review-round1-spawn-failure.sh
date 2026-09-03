#!/usr/bin/env bash
# Regression for #736: on a large diff, prompt summarization for one Round 1
# provider can outrun spawn_agent_capture_pid's PID-wait budget. Before this
# fix, the resulting non-zero exit propagated through orchestrate.sh's
# `set -eo pipefail`, killing review_run() mid-dispatch: no further Round 1
# providers were spawned, and every downstream octo_proof_finalize call
# (including the "all providers failed" path) was skipped — leaving
# state.json stuck at status "running" forever.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "review_run Round 1 spawn failure resilience (#736)"

REVIEW_SH="$PROJECT_ROOT/scripts/lib/review.sh"

# ── static guard: the exact unguarded pattern that caused #736 must be gone ──

test_case "round1 spawn call is guarded against a non-zero exit"
if grep -q 'if ! round1_pid=\$(spawn_agent_capture_pid' "$REVIEW_SH"; then
    test_pass
else
    test_fail "expected an 'if ! round1_pid=\$(spawn_agent_capture_pid ...)' guard in review.sh"
fi

test_case "no bare unguarded round1_pid assignment remains"
# The old buggy shape: a plain assignment with no if/guard around it, which
# aborts the whole function under `set -e` on any single provider failure.
if grep -qE '^\s*round1_pid=\$\(spawn_agent_capture_pid' "$REVIEW_SH"; then
    test_fail "found an unguarded 'round1_pid=\$(spawn_agent_capture_pid ...)' assignment"
else
    test_pass
fi

# ── behavioral: extract the real Round 1 dispatch loop and prove it survives
# a mid-fleet spawn failure under `set -e`, exactly as orchestrate.sh runs it ──

test_case "a single failed provider does not abort dispatch of the rest of the fleet"

LOOP_SRC=$(sed -n '/^    fleet_dispatch_begin$/,/^    fleet_dispatch_end$/p' "$REVIEW_SH")
if [[ -z "$LOOP_SRC" ]]; then
    test_fail "could not extract the Round 1 dispatch loop from review.sh (source drift?)"
else
    TEST_TMP_DIR="/tmp/octopus-tests-$$"
    mkdir -p "$TEST_TMP_DIR"
    trap 'rm -rf "$TEST_TMP_DIR"' EXIT

    HARNESS="$TEST_TMP_DIR/harness.sh"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -eo pipefail'  # mirrors orchestrate.sh exactly
        printf 'source %q\n' "$PROJECT_ROOT/scripts/lib/agent-spec.sh"
        echo 'RESULTS_DIR="'"$TEST_TMP_DIR"'"'
        echo 'timestamp="ts1"'
        echo 'fleet="codex:reviewer1:logic
gemini:reviewer2:style"'
        echo 'round1_files=(); round1_agent_types=(); round1_roles=(); round1_task_ids=(); round1_prompts=(); round1_pids=()'
        echo 'agent_prompt_base="base prompt"'
        echo 'log() { :; }'
        echo 'fleet_dispatch_begin() { :; }'
        echo 'fleet_dispatch_end() { :; }'
        echo 'review_agent_for_seat() { printf "%s\n" "$1"; }'
        # First fleet member fails PID capture (the #736 scenario); second succeeds.
        echo 'spawn_agent_capture_pid() {'
        echo '    if [[ "$1" == "codex" ]]; then'
        echo '        echo "spawn_agent produced no provider PID" >&2'
        echo '        return 1'
        echo '    fi'
        echo '    echo 424242'
        echo '}'
        echo 'run_round1() {'
        printf '%s\n' "$LOOP_SRC"
        echo '}'
        echo 'run_round1'
        echo 'printf "count=%d\n" "${#round1_pids[@]}"'
        echo 'printf "pid0=%s\n" "${round1_pids[0]:-}"'
        echo 'printf "pid1=%s\n" "${round1_pids[1]:-}"'
    } > "$HARNESS"

    if HARNESS_OUT=$(bash "$HARNESS" 2>&1); then
        count=$(printf '%s\n' "$HARNESS_OUT" | grep -o 'count=[0-9]*' | cut -d= -f2)
        pid0=$(printf '%s\n' "$HARNESS_OUT" | grep -o 'pid0=.*' | cut -d= -f2)
        pid1=$(printf '%s\n' "$HARNESS_OUT" | grep -o 'pid1=.*' | cut -d= -f2)
        if [[ "$count" == "2" && -z "$pid0" && "$pid1" == "424242" ]]; then
            test_pass
        else
            test_fail "expected both fleet members dispatched (count=2, pid0=empty, pid1=424242); got: $HARNESS_OUT"
        fi
    else
        test_fail "harness aborted under set -e instead of continuing past the failed provider: $HARNESS_OUT"
    fi
fi

test_case "provider fleet proof records resolved exact Round 1 identities"

LOOP_SRC=$(sed -n '/^    fleet_dispatch_begin$/,/^    fleet_dispatch_end$/p' "$REVIEW_SH")
if [[ -z "$LOOP_SRC" ]]; then
    test_fail "could not extract the Round 1 dispatch loop from review.sh (source drift?)"
else
    PROOF_HARNESS="$TEST_TMP_DIR/proof-harness.sh"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -eo pipefail'
        printf 'source %q\n' "$PROJECT_ROOT/scripts/lib/agent-spec.sh"
        echo 'RESULTS_DIR="'"$TEST_TMP_DIR"'"'
        echo 'timestamp="ts-proof"'
        echo 'fleet="codex:reviewer1:logic
claude-sonnet:reviewer2:architecture"'
        echo 'round1_files=(); round1_agent_types=(); round1_roles=(); round1_task_ids=(); round1_prompts=(); round1_pids=()'
        echo 'agent_prompt_base="base prompt"'
        echo 'proof_dir="proof-enabled"'
        echo 'log() { :; }'
        echo 'fleet_dispatch_begin() { :; }'
        echo 'fleet_dispatch_end() { :; }'
        echo 'review_agent_for_seat() {'
        echo '    if [[ "$2" == "reviewer1" ]]; then printf "%s\n" "commandcode:model-exact"; else printf "%s\n" "$1"; fi'
        echo '}'
        echo 'spawn_agent_capture_pid() { echo 424242; }'
        echo 'octo_proof_event() { printf "proof_type=%s\nproof_data=%s\n" "$2" "$3"; }'
        echo 'run_round1() {'
        printf '%s\n' "$LOOP_SRC"
        echo '}'
        echo 'run_round1'
    } > "$PROOF_HARNESS"

    if PROOF_OUT=$(bash "$PROOF_HARNESS" 2>&1) && \
       [[ "$PROOF_OUT" == *'proof_type=provider_fleet'* ]] && \
       [[ "$PROOF_OUT" == *'["commandcode:model-exact","claude-sonnet"]'* ]] && \
       [[ "$PROOF_OUT" != *'["codex","claude-sonnet"]'* ]]; then
        test_pass
    else
        test_fail "provider_fleet proof did not capture resolved identities: ${PROOF_OUT:-<empty>}"
    fi
fi

test_case "invalid fleet override finalizes proof and removes provider status under set -e"

LIFECYCLE_DIR="$TEST_TMP_DIR/fleet-validation-lifecycle"
mkdir -p "$LIFECYCLE_DIR/tmp" "$LIFECYCLE_DIR/results" "$LIFECYCLE_DIR/proof"
LIFECYCLE_HARNESS="$LIFECYCLE_DIR/harness.sh"
{
    echo '#!/usr/bin/env bash'
    echo 'set -eo pipefail'
    printf 'export HOME=%q\n' "$LIFECYCLE_DIR/home"
    printf 'export TMPDIR=%q\n' "$LIFECYCLE_DIR/tmp"
    printf 'export RESULTS_DIR=%q\n' "$LIFECYCLE_DIR/results"
    printf 'export PROOF_DIR=%q\n' "$LIFECYCLE_DIR/proof"
    echo "export OCTOPUS_REVIEW_LOGIC_AGENT='invalid-override'"
    printf 'source %q\n' "$REVIEW_SH"
    echo 'log() { printf "%s: %s\n" "$1" "$2" >&2; }'
    echo 'check_codex_auth_freshness() { return 0; }'
    echo 'parse_review_md() { REVIEW_ALWAYS_CHECK=""; REVIEW_STYLE_RULES=""; REVIEW_SKIP_PATTERNS=""; }'
    echo 'review_collect_diff() { printf "%s\n" "diff --git a/a b/a" "+changed"; }'
    echo 'octo_proof_enabled() { return 0; }'
    echo 'octo_proof_init() { mkdir -p "$PROOF_DIR"; printf "%s\n" "$PROOF_DIR"; }'
    echo 'octo_proof_event() { :; }'
    echo 'octo_proof_artifact() { cp "$3" "$PROOF_DIR/findings.json"; }'
    echo 'octo_proof_capture_provider_status() {'
    echo '    [[ -f "$2" ]] || return 91'
    echo '    printf "captured=%s\n" "$2" > "$PROOF_DIR/provider-status-captured"'
    echo '}'
    echo 'octo_proof_finalize() {'
    echo '    printf "status=%s\nsummary=%s\n" "$2" "$3" > "$PROOF_DIR/finalized"'
    echo '}'
    echo 'render_terminal_report() { :; }'
    echo 'review_run "{}"'
} > "$LIFECYCLE_HARNESS"

lifecycle_rc=0
/bin/bash "$LIFECYCLE_HARNESS" >"$LIFECYCLE_DIR/output" 2>&1 || lifecycle_rc=$?
status_file_count="$(find "$LIFECYCLE_DIR/tmp" -name 'octopus-provider-status.*' -type f | wc -l | tr -d ' ')"
if [[ "$lifecycle_rc" -eq 2 ]] && \
   grep -Fq 'status=fail' "$LIFECYCLE_DIR/proof/finalized" 2>/dev/null && \
   grep -Fq 'Review fleet validation failed with status 2.' "$LIFECYCLE_DIR/proof/finalized" 2>/dev/null && \
   [[ -s "$LIFECYCLE_DIR/proof/provider-status-captured" ]] && \
   jq -e '.findings == [] and (.warning | contains("Review fleet validation failed"))' \
      "$LIFECYCLE_DIR/proof/findings.json" >/dev/null 2>&1 && \
   [[ "$status_file_count" -eq 0 ]]; then
    test_pass
else
    test_fail "invalid fleet lifecycle was incomplete: rc=$lifecycle_rc temp_status_files=$status_file_count output=[$(tr '\n' ';' < "$LIFECYCLE_DIR/output")]"
fi

test_summary
