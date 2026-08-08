#!/usr/bin/env bash
# Provider lockout helpers must have exactly one definition.
#
# lock_provider, is_provider_locked, get_alternate_provider,
# reset_provider_lockouts, append_provider_history, read_provider_history and
# build_provider_context were defined twice — in lib/quality.sh and again in
# lib/provider-routing.sh — identical except for the fallback provider.
#
# orchestrate.sh sources quality.sh at :194 and provider-routing.sh at :205, so
# the second definition silently won. The effective fallback for a locked codex
# was therefore `gemini`, whose free tier is sunset and returns
# IneligibleTierError — the recovery path routed to a known-dead seat. The
# surviving quality.sh chain falls back to `agy`, the current Google seat, then
# to Claude for a genuinely separate failure domain.
#
# Nothing about that was visible in either file. It was decided by source order.
set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Provider fallback has a single owner"

LOCKOUT_FNS="lock_provider is_provider_locked get_alternate_provider reset_provider_lockouts append_provider_history read_provider_history build_provider_context"

# The assertion that matters: one definition each, repo-wide. Two definitions
# mean behaviour depends on source order, which is not reviewable.
test_case "each lockout helper is defined exactly once across scripts/"
dupes=""
for fn in $LOCKOUT_FNS; do
    n="$(grep -rlE "^${fn}\(\)" "$PROJECT_ROOT/scripts" 2>/dev/null | grep -c . || true)"
    [[ "${n:-0}" -le 1 ]] || dupes="$dupes ${fn}(${n})"
done
if [[ -z "$dupes" ]]; then
    test_pass
else
    test_fail "defined in more than one file:${dupes} — source order would decide which wins"
fi

test_case "the surviving definitions live in provider-lockout.sh"
missing=""
for fn in $LOCKOUT_FNS; do
    grep -qE "^${fn}\(\)" "$PROJECT_ROOT/scripts/lib/provider-lockout.sh" || missing="$missing $fn"
done
if [[ -z "$missing" ]]; then
    test_pass
else
    test_fail "not found in provider-lockout.sh:${missing}"
fi

# Behavioural check, not just structural: sourcing both files in the real order
# must still yield the intended fallback.
resolve_fallback() {
    bash -c '
        source "$1/scripts/lib/quality.sh" 2>/dev/null
        source "$1/scripts/lib/provider-routing.sh" 2>/dev/null
        LOCKED_PROVIDERS=" $2 "
        get_alternate_provider "$2" 2>/dev/null
    ' _ "$PROJECT_ROOT" "$1" 2>/dev/null | tail -1
}

test_case "a locked codex falls back to agy, not the sunset gemini seat"
got="$(resolve_fallback codex)"
if [[ "$got" == "agy" ]]; then
    test_pass
else
    test_fail "expected agy, got '${got}' — gemini's free tier is sunset (IneligibleTierError), so falling back to it routes into a known-dead seat"
fi

test_case "the fallback survives sourcing provider-routing.sh second"
# Explicitly mirrors orchestrate.sh's order (quality.sh :194, routing :205).
got="$(resolve_fallback codex)"
got2="$(bash -c '
    source "$1/scripts/lib/provider-routing.sh" 2>/dev/null
    source "$1/scripts/lib/quality.sh" 2>/dev/null
    LOCKED_PROVIDERS=" codex "
    get_alternate_provider codex 2>/dev/null
' _ "$PROJECT_ROOT" 2>/dev/null | tail -1)"
if [[ "$got" == "$got2" ]]; then
    test_pass
else
    test_fail "fallback depends on source order: forward='${got}' reversed='${got2}' — that is the bug this suite exists to prevent"
fi

# Guards a vacuous pass: if the helper stops resolving at all, the assertions
# above would compare two empty strings and agree.
test_case "get_alternate_provider actually resolves something"
if [[ -n "$(resolve_fallback codex)" ]]; then
    test_pass
else
    test_fail "resolved empty — the helper is not loading, so the comparisons above prove nothing"
fi

test_case "both consumers source the single owner rather than redefining it"
bad=""
for consumer in quality.sh provider-routing.sh; do
    grep -q 'provider-lockout.sh' "$PROJECT_ROOT/scripts/lib/$consumer" || bad="$bad $consumer"
done
if [[ -z "$bad" ]]; then
    test_pass
else
    test_fail "these do not source the single owner:${bad} — sourcing one of them standalone would leave the helpers undefined"
fi

# Neither original copy had complete coverage: quality.sh keyed on agy, the
# provider-routing.sh copy keyed on gemini. Keeping only one silently dropped
# an arm, so a locked provider was offered itself as its own alternate.
test_case "every routable provider has an alternate that is not itself"
selfref=""
for p in codex gemini gemini-fast agy claude-sonnet; do
    got="$(resolve_fallback "$p")"
    [[ -n "$got" && "$got" != "$p" ]] || selfref="$selfref ${p}(${got:-empty})"
done
if [[ -z "$selfref" ]]; then
    test_pass
else
    test_fail "these resolve to themselves, so lockout never routes anywhere:${selfref}"
fi

test_summary
