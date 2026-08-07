#!/usr/bin/env bash
# `grep -c ... || echo 0` breaks arithmetic on no-match (#786, #787).
#
# grep -c prints "0" AND exits 1 when nothing matches, so the `||` fires and
# appends a second zero. The variable becomes the two-line value $'0\n0', and
# the next numeric comparison dies:
#
#     hooks/done-criteria.sh: line 69: [[: 0
#     0: syntax error in expression (error token is "0")
#
# Reported twice against 9.60.0 on macOS Bash 3.2.57, in two different hooks
# that both run on ordinary user input: done-criteria.sh on any prompt over 30
# characters with no bullet lines, and output-compressor.sh on any verbose
# output with no timestamps.
#
# The correct form puts the fallback on the assignment, not inside the command
# substitution, so a no-match leaves a single clean zero:
#
#     n=$(grep -c ...) || n=0
#
# scripts/lib/heuristics.sh:24 already documented this exact trap and fixed it
# locally with safe_count(); the pattern survived everywhere else. This suite
# is the repo-wide guard that comment could not be.
set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "grep -c arithmetic safety (#786, #787)"

# Demonstrates the trap itself, so the suite documents why the rule exists
# rather than just asserting a grep. If a future bash makes grep -c exit 0 on
# no-match this fails loudly and the rule can be revisited.
test_case "the broken idiom really does produce a two-line value"
broken="$(echo "haystack" | grep -c "needle" || echo 0)"
if [[ "$broken" == *$'\n'* ]]; then
    test_pass
else
    test_fail "expected \$'0\\n0' from the broken idiom, got '${broken}' — the premise of this suite no longer holds"
fi

test_case "the corrected idiom produces a single usable zero"
fixed="$(echo "haystack" | grep -c "needle")" || fixed=0
if [[ "$fixed" == "0" ]] && [[ "$fixed" -eq 0 ]] 2>/dev/null; then
    test_pass
else
    test_fail "corrected idiom yielded '${fixed}', which is not arithmetic-safe"
fi

# The guard. Scans shipped code; tests/ is excluded because a miscount there
# fails the test that owns it rather than corrupting a user-facing decision.
test_case "no shipped script uses the broken idiom"
offenders="$(grep -rnE 'grep -c[^|#]*\|\|[[:space:]]*echo[[:space:]]+"?0"?' \
    "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/hooks" 2>/dev/null \
    | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
count="$(printf '%s' "$offenders" | grep -c . || true)"
if [[ "${count:-0}" -eq 0 ]]; then
    test_pass
else
    test_fail "${count} occurrence(s) of 'grep -c ... || echo 0'; use 'n=\$(grep -c ...) || n=0' instead:
$(printf '%s' "$offenders" | head -5)"
fi

# Guards a vacuous pass: if the scan roots move, the assertion above would
# report clean having examined nothing.
test_case "the scan actually covers shipped code"
scanned="$(find "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/hooks" -name '*.sh' -type f 2>/dev/null | grep -c . || true)"
if [[ "${scanned:-0}" -ge 50 ]]; then
    test_pass
else
    test_fail "only ${scanned} shell files found under scripts/ and hooks/ — the paths are wrong, so the guard proves nothing"
fi

# The two reported entry points, pinned by name and exercised end to end. A
# static grep alone would not prove the hooks recovered.
test_case "done-criteria.sh handles a bullet-free prompt without an arithmetic error"
out="$(printf '%s' '{"prompt":"Please inspect the hooks carefully and report the result after testing."}' \
    | bash "$PROJECT_ROOT/hooks/done-criteria.sh" 2>&1 || true)"
if grep -qi "syntax error" <<<"$out"; then
    test_fail "arithmetic error still raised: $(grep -i 'syntax error' <<<"$out" | head -1)"
else
    test_pass
fi

test_case "output-compressor.sh handles timestamp-free output without an arithmetic error"
out="$(printf '%s' '{"tool_output":"verbose output with no timestamps at all here"}' \
    | bash "$PROJECT_ROOT/hooks/output-compressor.sh" 2>&1 || true)"
if grep -qi "syntax error" <<<"$out"; then
    test_fail "arithmetic error still raised: $(grep -i 'syntax error' <<<"$out" | head -1)"
else
    test_pass
fi

test_summary
