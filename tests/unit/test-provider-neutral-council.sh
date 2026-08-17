#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Provider-neutral review council with role-based model routing"

TMP_HOME="$(mktemp -d)"
CHECKER="$TMP_HOME/check-providers.sh"
trap 'rm -rf "$TMP_HOME"' EXIT
mkdir -p "$TMP_HOME/.claude-octopus/config"
cat >"$CHECKER" <<'EOF'
#!/bin/sh
cat <<'STATUS'
PROVIDER_CHECK_START
codex:available
commandcode:available
agy:missing
perplexity:missing
openrouter:missing
PROVIDER_CHECK_END
STATUS
EOF
chmod +x "$CHECKER"
cat >"$TMP_HOME/.claude-octopus/config/providers.json" <<'EOF'
{
  "version":"3.0",
  "providers": {
    "codex": {"default":"gpt-5.6-sol"},
    "commandcode": {"default":"deepseek/deepseek-v4-flash"},
    "claude": {"default":"claude-sonnet-5"}
  },
  "routing":{"phases":{},"roles":{"architecture-reviewer":{"provider":"commandcode","model":"minimaxai/minimax-m3"}}},
  "tiers":{},
  "overrides":{}
}
EOF

export HOME="$TMP_HOME"
export OCTOPUS_PROVIDER_CHECKER="$CHECKER"
export OCTOPUS_ALLOWED_PROVIDERS="codex commandcode claude"

output="$(bash "$PROJECT_ROOT/scripts/helpers/build-fleet.sh" review standard test 2>/dev/null)"

test_case "review council uses admitted council-capable providers without AGY/Perplexity"
if echo "$output" | cut -d'|' -f1 | grep -Eq '^(agy|perplexity)$'; then
  test_fail "unusable provider entered council: $output"
elif echo "$output" | cut -d'|' -f1 | grep -q '^commandcode$'; then
  test_pass
else
  test_fail "CommandCode did not naturally fill a council seat: $output"
fi

test_case "review seats remain role labels rather than provider identities"
labels="$(echo "$output" | cut -d'|' -f2 | tr '\n' '|')"
case "$labels" in
  *"Logic Reviewer"*"Security Reviewer"*"Architecture Reviewer"*"CVE Reviewer"*) test_pass ;;
  *) test_fail "review role labels changed: $labels" ;;
esac

test_case "role routing resolves a role-specific model without changing provider identity"
log() { :; }
export PLUGIN_DIR="$PROJECT_ROOT"
export OCTOPUS_PLATFORM=Linux
source "$PROJECT_ROOT/scripts/lib/model-resolver.sh"
model="$(resolve_octopus_model commandcode commandcode review architecture-reviewer)"
if [[ "$model" == "minimaxai/minimax-m3" ]]; then
  test_pass
else
  test_fail "expected role-routed MiniMax model, got '$model'"
fi

test_summary
