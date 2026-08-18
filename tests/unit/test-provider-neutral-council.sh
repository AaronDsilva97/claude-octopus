#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Provider-neutral review council with role-based model routing"

TMP_HOME="$TEST_TMP_DIR/provider-neutral-council"
CHECKER="$TMP_HOME/check-providers.sh"
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
    "commandcode": {
      "default":"deepseek/deepseek-v4-flash",
      "roles":{"architecture-reviewer":"minimaxai/minimax-m3"}
    },
    "claude": {"default":"claude-sonnet-5"}
  },
  "routing":{"phases":{},"roles":{}},
  "tiers":{},
  "overrides":{}
}
EOF

export HOME="$TMP_HOME"
export OCTOPUS_PROVIDER_CHECKER="$CHECKER"
export OCTOPUS_ALLOWED_PROVIDERS="codex commandcode claude"

output="$(bash "$PROJECT_ROOT/scripts/helpers/build-fleet.sh" review standard test 2>/dev/null)"
provider_ids="$(printf '%s\n' "$output" | cut -d'|' -f1)"

test_case "review council uses admitted council-capable providers without AGY/Perplexity"
case "$provider_ids" in
  *$'\nagy'$'\n'*|agy$'\n'*|*$'\nperplexity'$'\n'*|perplexity$'\n'*)
    test_fail "unusable provider entered council: $output"
    ;;
  *)
    case $'\n'"$provider_ids"$'\n' in
      *$'\ncommandcode\n'*) test_pass ;;
      *) test_fail "CommandCode did not naturally fill a council seat: $output" ;;
    esac
    ;;
esac

test_case "review council emits four seats in deterministic policy order"
seat_count="$(printf '%s\n' "$provider_ids" | sed '/^$/d' | wc -l | tr -d ' ')"
expected_provider_ids="$(printf '%s\n' claude-sonnet codex commandcode claude-sonnet)"
if [[ "$seat_count" != "4" ]]; then
  test_fail "expected four review seats, got $seat_count: $output"
elif [[ "$provider_ids" != "$expected_provider_ids" ]]; then
  test_fail "expected provider order [claude-sonnet,codex,commandcode,claude-sonnet], got [$(printf '%s' "$provider_ids" | paste -sd, -)]"
else
  test_pass
fi

test_case "invalid council provider policy fails closed"
if OCTOPUS_COUNCIL_DEFAULT_PROVIDERS="codex,codex" bash "$PROJECT_ROOT/scripts/helpers/build-fleet.sh" review standard test >/dev/null 2>&1; then
  test_fail "duplicate council provider policy unexpectedly succeeded"
else
  test_pass
fi

test_case "review seats remain role labels rather than provider identities"
labels="$(echo "$output" | cut -d'|' -f2 | tr '\n' '|')"
case "$labels" in
  *"Logic Reviewer"*"Security Reviewer"*"Architecture Reviewer"*"CVE Reviewer"*) test_pass ;;
  *) test_fail "review role labels changed: $labels" ;;
esac

test_case "provider-local role model resolves without changing provider identity"
log() { :; }
export PLUGIN_DIR="$PROJECT_ROOT"
export OCTOPUS_PLATFORM=Linux
source "$PROJECT_ROOT/scripts/lib/model-resolver.sh"
model="$(resolve_octopus_model commandcode commandcode review architecture-reviewer)"
if [[ "$model" == "minimaxai/minimax-m3" ]]; then
  test_pass
else
  test_fail "expected provider-local MiniMax role model, got '$model'"
fi

test_case "provider-local role model does not become a provider route"
source "$PROJECT_ROOT/scripts/lib/execution-profile.sh"
provider="$(octopus_execution_profile_provider review review architecture-reviewer commandcode)"
if [[ "$provider" == "commandcode" ]]; then
  test_pass
else
  test_fail "provider-local role model changed provider selection to '$provider'"
fi

test_summary
