#!/usr/bin/env bash
# The release role table must affect the canonical workflow resolver (#970).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "production role-mapping reachability (#970)"

tmp_home="$TEST_TMP_DIR/home"
tmp_bin="$TEST_TMP_DIR/bin"
config="$tmp_home/.claude-octopus/config/providers.json"
mkdir -p "$tmp_bin" "$(dirname "$config")"
printf '%s\n' '{"routing":{"roles":{},"phases":{}}}' > "$config"

cat > "$tmp_bin/codex" <<'MOCK_CODEX'
#!/usr/bin/env bash
exit 0
MOCK_CODEX
chmod +x "$tmp_bin/codex"

resolve_provider() {
    local phase="$1" operation="$2" role="$3" default_provider="$4"
    shift 4
    env "HOME=$tmp_home" "PATH=$tmp_bin:$PATH" "OCTOPUS_PROVIDERS_CONFIG=$config" "$@" \
        bash -c '
            set -euo pipefail
            export PLUGIN_DIR="$1"
            source "$1/scripts/lib/features.sh"
            source "$1/scripts/lib/execution-profile.sh"
            source "$1/scripts/lib/agent-utils.sh"
            octopus_execution_profile_provider "$2" "$3" "$4" "$5"
        ' bash "$PROJECT_ROOT" "$phase" "$operation" "$role" "$default_provider"
}

test_case "release role mapping overrides a stale historical caller default"
got="$(resolve_provider tangle coding implementer claude-sonnet)"
if [[ "$got" == codex ]]; then
    test_pass
else
    test_fail "expected implementer role to resolve to codex, got '$got'"
fi

test_case "the legacy role opt-out reaches the production resolver"
got="$(resolve_provider tangle coding architect claude-sonnet OCTOPUS_LEGACY_ROLES=1)"
if [[ "$got" == codex ]]; then
    test_pass
else
    test_fail "expected legacy architect mapping to resolve to codex, got '$got'"
fi

test_case "reviewer consent is reachable through the production resolver"
got="$(resolve_provider deliver review reviewer codex-review OCTOPUS_REVIEWER_FLIP=claude)"
if [[ "$got" == claude-opus ]]; then
    test_pass
else
    test_fail "expected consent-gated reviewer flip to resolve to claude-opus, got '$got'"
fi

test_case "an explicit operation override still has highest precedence"
got="$(resolve_provider tangle coding implementer claude-sonnet OCTOPUS_TANGLE_CODING_AGENT=agy)"
if [[ "$got" == agy ]]; then
    test_pass
else
    test_fail "expected explicit tangle coding override to win, got '$got'"
fi

test_case "a configured role route still outranks the release role table"
jq '.routing.roles.implementer = "ollama:local-model"' "$config" > "$config.tmp"
mv "$config.tmp" "$config"
got="$(resolve_provider tangle coding implementer claude-sonnet)"
if [[ "$got" == ollama ]]; then
    test_pass
else
    test_fail "expected configured implementer route to win, got '$got'"
fi

test_summary
