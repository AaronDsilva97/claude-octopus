#!/usr/bin/env bash
# Regression coverage for release validation helpers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATION_LIB="$PROJECT_ROOT/scripts/lib/release-validation.sh"
VALIDATE_RELEASE="$PROJECT_ROOT/scripts/validate-release.sh"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
source "$VALIDATION_LIB"

test_suite "release validation helpers"

test_nested_skill_discovery() {
    test_case "skill discovery preserves ordinary and nested registration paths"

    local fixture
    fixture="$(mktemp -d "${TMPDIR:-/tmp}/octo-release-validation.XXXXXX")"
    mkdir -p \
        "$fixture/skills/plain-skill" \
        "$fixture/skills/starter-pack/nested-skill" \
        "$fixture/skills/starter-pack/not-a-skill"
    touch \
        "$fixture/skills/plain-skill/SKILL.md" \
        "$fixture/skills/starter-pack/nested-skill/SKILL.md" \
        "$fixture/skills/starter-pack/not-a-skill/README.md"

    local actual expected
    actual="$(octo_release_skill_files "$fixture")"
    expected=$'plain-skill\nstarter-pack/nested-skill'
    rm -rf "$fixture"

    if [[ "$actual" == "$expected" ]]; then
        test_pass
    else
        test_fail "unexpected skill paths: ${actual}"
    fi
}

test_validator_uses_recursive_skill_discovery() {
    test_case "validate-release delegates skill discovery to the tested helper"

    if grep -Fq 'octo_release_skill_files "$ROOT_DIR"' "$VALIDATE_RELEASE"; then
        test_pass
    else
        test_fail "validate-release does not use octo_release_skill_files"
    fi
}

test_nested_skill_discovery
test_validator_uses_recursive_skill_discovery

test_summary
