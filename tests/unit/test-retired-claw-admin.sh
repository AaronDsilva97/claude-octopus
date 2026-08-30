#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "retired claw admin boundary"

assert_absent() {
    local relative_path="$1"
    test_case "$relative_path is retired"
    if [[ ! -e "$PROJECT_ROOT/$relative_path" ]]; then
        test_pass
    else
        test_fail "$relative_path should not ship"
    fi
}

assert_present() {
    local relative_path="$1"
    test_case "$relative_path remains available"
    if [[ -e "$PROJECT_ROOT/$relative_path" ]]; then
        test_pass
    else
        test_fail "$relative_path is required for opt-in OpenClaw compatibility"
    fi
}

assert_text_absent() {
    local relative_path="$1"
    local pattern="$2"
    local label="$3"
    test_case "$label"
    if [[ ! -f "$PROJECT_ROOT/$relative_path" ]]; then
        test_fail "$relative_path must remain present for this boundary check"
        return
    fi
    if ! grep -q -- "$pattern" "$PROJECT_ROOT/$relative_path"; then
        test_pass
    else
        test_fail "$relative_path still contains retired admin wiring: $pattern"
    fi
}

for relative_path in \
    .claude/skills/skill-claw \
    .cursor-plugin/commands/octo-claw.md \
    agents/personas/openclaw-admin.md \
    commands/claw.md \
    hooks/sysadmin-safety-gate.sh \
    skills/skill-claw; do
    assert_absent "$relative_path"
done

assert_text_absent .claude-plugin/plugin.json 'skills/skill-claw' \
    "plugin manifest does not register skill-claw"
assert_text_absent .claude-plugin/plugin.json 'commands/claw.md' \
    "plugin manifest does not register the claw command"
assert_text_absent agents/config.yaml 'openclaw-admin' \
    "agent registry does not expose openclaw-admin"
assert_text_absent agents/config.yaml 'skill-claw' \
    "agent registry does not route to skill-claw"
assert_text_absent docs/COMMAND-REFERENCE.md '/octo:claw' \
    "command reference does not advertise /octo:claw"
assert_text_absent docs/COMMAND-REFERENCE.md 'manage my openclaw server' \
    "command reference does not retain claw admin routing examples"
assert_text_absent openclaw/src/tools/index.ts 'skill-claw' \
    "generated OpenClaw registry excludes skill-claw"
assert_text_absent openclaw/dist/tools/index.js 'skill-claw' \
    "built OpenClaw registry excludes skill-claw"
assert_text_absent tests/smoke/test-safety-hooks.sh 'sysadmin-safety-gate' \
    "safety smoke tests do not invoke the retired sysadmin hook"
assert_text_absent SECURITY.md 'sysadmin-safety-gate' \
    "security guidance does not document the retired sysadmin hook"

for relative_path in \
    .mcp.json \
    mcp-server/src/index.ts \
    openclaw/package.json \
    openclaw/openclaw.plugin.json \
    scripts/build-openclaw.sh \
    tests/unit/test-openclaw-compat.sh \
    tests/validate-openclaw.sh; do
    assert_present "$relative_path"
done

test_case "retained OpenClaw compatibility contract passes"
if output=$(bash "$PROJECT_ROOT/tests/unit/test-openclaw-compat.sh" 2>&1); then
    test_pass
else
    test_fail "OpenClaw compatibility suite failed: $output"
fi

test_summary
