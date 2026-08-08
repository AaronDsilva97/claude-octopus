#!/usr/bin/env bash
# The background-permission prompt must disclose every billed provider.
#
# request_background_permission asks the user to approve spending their own
# money. It named exactly two providers:
#
#     if echo "$providers" | grep -q "codex"; then ... OPENAI_API_KEY
#     if echo "$providers" | grep -q "gemini"; then ... GEMINI_API_KEY
#
# The registry has fifteen. So a workflow dispatching grok, qwen, copilot,
# perplexity, openrouter, agy, atlascloud, opencode, commandcode or
# cursor-agent asked for approval while telling the user nothing about those
# seats — the prompt showed only "Claude — included with Claude Code", which
# reads as costing nothing.
#
# Found proactively by diffing the hardcoded provider lists against the registry
# (#762), the same drift that produced #696, #697, #705 and #769. Disclosure is
# now derived, so a provider added to the registry is disclosed automatically.
set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Background-permission provider disclosure"

MANAGER="$PROJECT_ROOT/scripts/permissions-manager.sh"

test_case "the permissions manager exists and parses under the Bash 3.2 floor"
if [[ -f "$MANAGER" ]] && /bin/bash -n "$MANAGER" 2>/dev/null; then
    test_pass
else
    test_fail "missing or unparseable $MANAGER"
fi

# Reproduces the disclosure loop rather than driving the interactive prompt,
# which blocks on a read. If the loop is refactored this must be updated — the
# static guards below exist to catch that.
disclose() {
    bash -c '
        source "'"$PROJECT_ROOT"'/scripts/lib/provider-registry.sh" 2>/dev/null || true
        providers="$1"
        _billed=0
        for _p in $providers; do
            case "$_p" in
                claude|claude-sdk|claude-sonnet|claude-opus*)
                    echo "included:$_p"; continue ;;
            esac
            _org="$(octo_provider_org "$_p" 2>/dev/null || true)"
            echo "billed:$_p:${_org:-provider}"
            _billed=$((_billed + 1))
        done
        echo "count:$_billed"
    ' _ "$1" 2>/dev/null
}

test_case "a non-codex, non-gemini provider is disclosed as billed"
out="$(disclose "grok")"
if grep -q '^billed:grok:' <<< "$out"; then
    test_pass
else
    test_fail "grok was not disclosed — this is the exact case the old code stayed silent about: $out"
fi

test_case "every billed provider in a multi-seat run is named"
out="$(disclose "grok qwen perplexity claude")"
missing=""
for p in grok qwen perplexity; do
    grep -q "^billed:${p}:" <<< "$out" || missing="$missing $p"
done
if [[ -z "$missing" ]] && grep -q '^count:3$' <<< "$out"; then
    test_pass
else
    test_fail "undisclosed seats:${missing:- none}; output: $out"
fi

test_case "Claude seats are disclosed as included, not billed"
out="$(disclose "claude")"
if grep -q '^included:claude$' <<< "$out" && grep -q '^count:0$' <<< "$out"; then
    test_pass
else
    test_fail "expected claude to be included and not counted as billed: $out"
fi

# Silence about an unrecognised seat is the failure this replaced, so an
# unknown provider must still be disclosed rather than skipped.
test_case "an unregistered provider is still disclosed"
out="$(disclose "some-future-provider")"
if grep -q '^billed:some-future-provider:' <<< "$out"; then
    test_pass
else
    test_fail "an unknown seat was not disclosed — staying silent because the registry lagged is the original bug: $out"
fi

# Static guards: the disclosure must stay derived rather than drifting back to
# a hardcoded pair.
test_case "disclosure is not hardcoded to codex and gemini"
if grep -qE 'grep -q "codex"' "$MANAGER" || grep -qE 'grep -q "gemini"' "$MANAGER"; then
    test_fail "provider disclosure is hardcoded again; derive it from the registry"
else
    test_pass
fi

test_case "the manager loads the provider registry"
if grep -q 'provider-registry.sh' "$MANAGER"; then
    test_pass
else
    test_fail "permissions-manager.sh must source the registry to disclose seats it does not hardcode"
fi

# The cost line previously read as a total while ignoring the provider list
# entirely. It must not imply it accounted for seats it never looked at.
test_case "the cost estimate does not present itself as a multi-provider total"
if grep -q 'Estimated API cost per provider' "$MANAGER"; then
    test_pass
else
    test_fail "cost wording must state it is per provider; estimate_cost ignores its \$providers argument"
fi

test_case "estimate_cost records that it ignores the provider list"
body="$(sed -n '/^estimate_cost()/,/^}/p' "$MANAGER")"
if grep -q 'does NOT scale' <<< "$body"; then
    test_pass
else
    test_fail "estimate_cost accepts \$providers and never uses it; that must be stated, not left to look accounted for"
fi

test_summary
