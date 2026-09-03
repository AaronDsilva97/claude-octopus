#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "Codex plugin manifest"

test_case "Codex default prompts stay within the host limit of three"
if jq -e '.interface.defaultPrompt | (type == "array" and length <= 3)' \
    "$PROJECT_ROOT/.codex-plugin/plugin.json" >/dev/null; then
    test_pass
else
    test_fail "Codex supports at most three interface.defaultPrompt entries"
fi

test_case "Codex metadata names all eleven external providers"
if jq -e '
    (.description | contains("Kimi Code")) and
    (.interface.shortDescription | contains("11 providers")) and
    (.interface.longDescription | contains("eleven external AI providers")) and
    (.interface.longDescription | contains("Kimi Code"))
' "$PROJECT_ROOT/.codex-plugin/plugin.json" >/dev/null; then
    test_pass
else
    test_fail "Codex metadata must count eleven providers and include Kimi Code"
fi

test_summary
