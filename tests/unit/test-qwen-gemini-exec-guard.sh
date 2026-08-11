#!/usr/bin/env bash
# Tests for Qwen/Gemini direct-dispatch guard hook (issue #860).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Qwen/Gemini direct-dispatch guard"

HOOK="$PROJECT_ROOT/hooks/qwen-gemini-exec-guard.sh"

run_hook() {
    local command="$1"
    printf '{"tool_input":{"command":%s}}\n' "$(printf '%s' "$command" | jq -Rs .)" | bash "$HOOK"
}

assert_denied() {
    local desc="$1" command="$2" needle="$3"
    test_case "$desc"
    output="$(run_hook "$command")"
    if [[ "$output" == *'"permissionDecision":"deny"'* ]] && [[ "$output" == *"$needle"* ]]; then
        test_pass
    else
        test_fail "expected deny mentioning '$needle', got: ${output:-<empty>}"
    fi
}

assert_allowed() {
    local desc="$1" command="$2"
    test_case "$desc"
    output="$(run_hook "$command")"
    if [[ -z "$output" ]]; then
        test_pass
    else
        test_fail "expected allow (silent pass-through), got: ${output:-<empty>}"
    fi
}

assert_denied "blocks bare qwen prompt dispatch" \
    'qwen "summarize this repo"' \
    'orchestrate.sh probe-single qwen'

assert_denied "blocks bare gemini invocation" \
    'gemini "summarize this repo"' \
    'orchestrate.sh probe-single agy'

assert_allowed "allows qwen --version introspection" 'qwen --version'
assert_allowed "allows qwen --help introspection" 'qwen --help'
assert_allowed "allows gemini --version introspection" 'gemini --version'
assert_allowed "allows gemini --help introspection" 'gemini --help'
assert_allowed "allows which qwen" 'which qwen'
assert_allowed "allows command -v qwen" 'command -v qwen'
assert_allowed "allows unrelated command mentioning qwen in text" 'echo "ask qwen about this"'
assert_allowed "allows unrelated command" 'ls -la'

assert_denied "blocks qwen after && chain" \
    'true && qwen "prompt"' \
    'orchestrate.sh probe-single qwen'

assert_denied "blocks gemini inside a subshell" \
    '(gemini "prompt")' \
    'orchestrate.sh probe-single agy'

assert_denied "blocks qwen after ; chain" \
    'echo hi; qwen "prompt"' \
    'orchestrate.sh probe-single qwen'

assert_denied "blocks qwen inside command substitution" \
    'echo $(qwen "prompt")' \
    'orchestrate.sh probe-single qwen'

assert_denied "blocks qwen inside backticks" \
    'echo `qwen "prompt"`' \
    'orchestrate.sh probe-single qwen'

test_summary
