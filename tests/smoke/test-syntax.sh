#!/bin/bash
# tests/smoke/test-syntax.sh
# Validates shell script syntax

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "Syntax Validation"

test_orchestrate_syntax() {
    test_case "orchestrate.sh has valid syntax"

    local orchestrate="$PROJECT_ROOT/scripts/orchestrate.sh"

    if [[ ! -f "$orchestrate" ]]; then
        test_fail "orchestrate.sh not found"
        return 1
    fi

    # Run bash syntax check
    if bash -n "$orchestrate" 2>/dev/null; then
        test_pass
    else
        test_fail "Syntax error in orchestrate.sh"
        return 1
    fi
}

test_main_skill_syntax() {
    test_case ".claude/skills/skill-parallel-agents has valid frontmatter"

    local main_skill="$PROJECT_ROOT/.claude/skills/skill-parallel-agents.md"
    if [[ ! -f "$main_skill" ]]; then
        main_skill="$PROJECT_ROOT/.claude/skills/skill-parallel-agents/SKILL.md"
    fi

    if [[ ! -f "$main_skill" ]]; then
        test_fail "skill-parallel-agents skill not found"
        return 1
    fi

    # Check frontmatter exists
    if head -n 1 "$main_skill" | grep -q "^---$"; then
        test_pass
    else
        test_fail "No frontmatter found in skill-parallel-agents"
        return 1
    fi
}

test_helper_scripts_syntax() {
    test_case "All test helper scripts have valid syntax"

    local helpers_dir="$SCRIPT_DIR/../helpers"
    local failed=0

    for script in "$helpers_dir"/*.sh; do
        if [[ -f "$script" ]]; then
            if ! bash -n "$script" 2>/dev/null; then
                echo "  Syntax error in: $(basename "$script")"
                failed=1
            fi
        fi
    done

    if [[ $failed -eq 0 ]]; then
        test_pass
    else
        test_fail "One or more helper scripts have syntax errors"
        return 1
    fi
}

test_executable_permissions() {
    test_case "orchestrate.sh is executable"

    local orchestrate="$PROJECT_ROOT/scripts/orchestrate.sh"

    if [[ -x "$orchestrate" ]]; then
        test_pass
    else
        test_fail "orchestrate.sh is not executable"
        return 1
    fi
}

# One authoritative syntax sweep over the shipped scripts.
#
# Previously only orchestrate.sh and tests/helpers/*.sh were checked here, so
# scripts/lib/*.sh and scripts/helpers/*.sh had no syntax gate in CI at all.
# Seven unit suites had each grown their own `workflows.sh has valid bash
# syntax` case to compensate, and the only comprehensive sweeps lived in the
# tests/ root files that no CI gate runs (#741). That is the worst of both:
# the same file checked seven times, and 95 others not checked at all.
test_shipped_scripts_syntax() {
    test_case "All shipped scripts have valid bash syntax"

    local failed=0 checked=0 script
    for script in "$PROJECT_ROOT"/scripts/lib/*.sh "$PROJECT_ROOT"/scripts/helpers/*.sh; do
        [[ -f "$script" ]] || continue
        checked=$((checked + 1))
        if ! bash -n "$script" 2>/dev/null; then
            echo "  Syntax error in: ${script#"$PROJECT_ROOT"/}"
            failed=1
        fi
    done

    # Guards a vacuous pass: if the globs stop matching, every file would be
    # skipped and this would report success having checked nothing.
    if [[ "$checked" -lt 50 ]]; then
        test_fail "only ${checked} scripts matched — the glob is wrong, so this assertion proves nothing"
        return 1
    fi

    if [[ $failed -eq 0 ]]; then
        test_pass
    else
        test_fail "One or more shipped scripts have syntax errors"
        return 1
    fi
}

# Run tests
test_orchestrate_syntax
test_main_skill_syntax
test_helper_scripts_syntax
test_shipped_scripts_syntax
test_executable_permissions

test_summary
