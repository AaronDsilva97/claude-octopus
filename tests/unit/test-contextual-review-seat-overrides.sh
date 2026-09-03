#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Contextual review seat overrides"

export PLUGIN_DIR="$PROJECT_ROOT"
export HOME="$TEST_TMP_DIR/contextual-review-seat-overrides"
mkdir -p "$HOME/.claude-octopus/config"
source "$PROJECT_ROOT/scripts/lib/provider-registry.sh"
source "$PROJECT_ROOT/scripts/lib/agent-spec.sh"
source "$PROJECT_ROOT/scripts/lib/model-resolver.sh"
source "$PROJECT_ROOT/scripts/lib/review.sh"

log() { :; }
octo_provider_allowed() {
  case "$(octo_agent_spec_provider "$1")" in
    codex|claude|commandcode) return 0 ;;
    *) return 1 ;;
  esac
}
unset OCTOPUS_REVIEW_SINGLE_PROVIDER
export OCTOPUS_REVIEW_LOGIC_AGENT='openai:gpt-5.6-luna'
export OCTOPUS_REVIEW_SECURITY_AGENT='claude:claude-opus-5'
export OCTOPUS_REVIEW_ARCHITECTURE_AGENT='anthropic:claude-opus-5'
export OCTOPUS_REVIEW_CVE_AGENT='command-code:tencent/hy3-paid'
export OCTOPUS_REVIEW_DIVERSITY_AGENT='commandcode:qwen/qwen3.8-27b'
export OCTOPUS_REVIEW_VERIFIER_AGENT='codex:gpt-5.6-luna'
export OCTOPUS_REVIEW_DEBATER_AGENT='commandcode:qwen/qwen3.8-27b'
export OCTOPUS_REVIEW_SYNTHESIZER_AGENT='commandcode:thinkingmachines/inkling-small'

test_case "semantic seats canonicalize registered aliases to executable provider:model specs"
if [[ "$(review_agent_for_seat codex implementation-logic-reviewer)" == 'codex:gpt-5.6-luna' ]] && \
   [[ "$(review_agent_for_seat claude-sonnet implementation-security-reviewer)" == "$OCTOPUS_REVIEW_SECURITY_AGENT" ]] && \
   [[ "$(review_agent_for_seat claude-sonnet implementation-architecture-reviewer)" == 'claude:claude-opus-5' ]] && \
   [[ "$(review_agent_for_seat perplexity implementation-cve-reviewer)" == 'commandcode:tencent/hy3-paid' ]] && \
   [[ "$(review_agent_for_seat codex implementation-verifier)" == "$OCTOPUS_REVIEW_VERIFIER_AGENT" ]] && \
   [[ "$(review_agent_for_seat codex implementation-debater)" == "$OCTOPUS_REVIEW_DEBATER_AGENT" ]] && \
   [[ "$(review_agent_for_seat claude-sonnet implementation-synthesizer)" == "$OCTOPUS_REVIEW_SYNTHESIZER_AGENT" ]]; then
  test_pass
else
  test_fail "semantic seat override mismatch"
fi

test_case "blank whitespace and provider-only seat overrides fail closed"
malformed_ok=true
for malformed in '' '   ' 'claude' 'claude:' ' claude:claude-opus-5' 'claude:claude-opus-5 '; do
  OCTOPUS_REVIEW_SECURITY_AGENT="$malformed"
  rc=0
  review_agent_for_seat claude-sonnet implementation-security-reviewer >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || malformed_ok=false
done
if [[ "$malformed_ok" == true ]]; then
  test_pass
else
  test_fail "a malformed contextual seat override was admitted"
fi
OCTOPUS_REVIEW_SECURITY_AGENT='claude:claude-opus-5'

test_case "every explicitly blank review seat override fails closed"
blank_overrides_ok=true
for role in \
  implementation-logic-reviewer \
  implementation-security-reviewer \
  implementation-architecture-reviewer \
  implementation-cve-reviewer \
  implementation-diversity-reviewer \
  implementation-verifier \
  implementation-debater \
  implementation-synthesizer; do
  env_name="$(review_seat_override_env_name "$role")"
  saved_value="${!env_name-}"
  printf -v "$env_name" '%s' ''
  export "$env_name"
  rc=0
  review_agent_for_seat codex "$role" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || blank_overrides_ok=false
  printf -v "$env_name" '%s' "$saved_value"
  export "$env_name"
done
if [[ "$blank_overrides_ok" == true ]]; then
  test_pass
else
  test_fail "an explicitly blank review seat override was treated as unset"
fi

test_case "Round 1 rejects an explicitly blank diversity override"
saved_diversity="$OCTOPUS_REVIEW_DIVERSITY_AGENT"
OCTOPUS_REVIEW_DIVERSITY_AGENT=''
blank_diversity_rc=0
review_fleet_with_override_seats 'codex:implementation-logic-reviewer:logic' >/dev/null 2>&1 || blank_diversity_rc=$?
OCTOPUS_REVIEW_DIVERSITY_AGENT="$saved_diversity"
if [[ "$blank_diversity_rc" -ne 0 ]]; then
  test_pass
else
  test_fail "blank diversity override was skipped instead of rejected"
fi

test_case "single-provider override keeps global precedence"
OCTOPUS_REVIEW_SINGLE_PROVIDER=codex
if [[ "$({
  review_single_provider_is_available() { [[ "$1" == codex ]]; }
  review_agent_for_seat claude-sonnet implementation-synthesizer
})" == 'codex' ]]; then
  test_pass
else
  test_fail "single-provider override did not take precedence"
fi
unset OCTOPUS_REVIEW_SINGLE_PROVIDER

test_case "disallowed seat override fails closed"
OCTOPUS_REVIEW_SECURITY_AGENT='agy:gemini-3.1-pro'
rc=0
review_agent_for_seat claude-sonnet implementation-security-reviewer >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
  test_pass
else
  test_fail "disallowed seat override was accepted"
fi
OCTOPUS_REVIEW_SECURITY_AGENT='claude:claude-opus-5'

test_case "unknown seat providers fail closed when the allowlist is unset"
octo_provider_allowed() { return 0; }
OCTOPUS_REVIEW_SECURITY_AGENT='unknown-provider:some-model'
rc=0
review_agent_for_seat claude-sonnet implementation-security-reviewer >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
  test_pass
else
  test_fail "unknown provider was admitted when the allowlist allowed all registered providers"
fi
octo_provider_allowed() {
  case "$(octo_agent_spec_provider "$1")" in
    codex|claude|commandcode) return 0 ;;
    *) return 1 ;;
  esac
}
OCTOPUS_REVIEW_SECURITY_AGENT='claude:claude-opus-5'

test_case "Round 1 override seats are emitted exactly once with configured providers"
# build_review_fleet obtains its configured fleet through command substitution,
# which strips the producer's trailing newline before override seats are added.
fleet=$'codex:implementation-logic-reviewer:correctness and logic bugs, edge cases, regressions\nclaude-sonnet:implementation-architecture-reviewer:architecture, integration, API contracts, breaking changes'
expanded="$(review_fleet_with_override_seats "$fleet")"
logic_provider="${OCTOPUS_REVIEW_LOGIC_AGENT%%:*}"
security_provider="${OCTOPUS_REVIEW_SECURITY_AGENT%%:*}"
cve_provider="${OCTOPUS_REVIEW_CVE_AGENT%%:*}"
diversity_provider="${OCTOPUS_REVIEW_DIVERSITY_AGENT%%:*}"
expanded_line_count="$(printf '%s\n' "$expanded" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
if [[ "$expanded_line_count" -eq 5 ]] && \
   [[ "$(grep -cE '^[^:]+:implementation-logic-reviewer:' <<< "$expanded")" -eq 1 ]] && \
   [[ "$(grep -cE '^[^:]+:implementation-architecture-reviewer:' <<< "$expanded")" -eq 1 ]] && \
   [[ "$(grep -cE '^[^:]+:implementation-security-reviewer:' <<< "$expanded")" -eq 1 ]] && \
   [[ "$(grep -cE '^[^:]+:implementation-cve-reviewer:' <<< "$expanded")" -eq 1 ]] && \
   [[ "$(grep -cE '^[^:]+:implementation-diversity-reviewer:' <<< "$expanded")" -eq 1 ]] && \
   [[ "$(grep -cE '^codex:implementation-logic-reviewer:' <<< "$expanded")" -eq 1 ]] && \
   [[ "$(grep -cE "^${security_provider}:implementation-security-reviewer:" <<< "$expanded")" -eq 1 ]] && \
   [[ "$(grep -cE '^commandcode:implementation-cve-reviewer:' <<< "$expanded")" -eq 1 ]] && \
   [[ "$(grep -cE "^${diversity_provider}:implementation-diversity-reviewer:" <<< "$expanded")" -eq 1 ]]; then
  test_pass
else
  test_fail "Round 1 generated fleet did not preserve unique configured-provider seats: $(tr '\n' '|' <<< "$expanded")"
fi

test_case "unconfigured roles preserve upstream default executor"
unset OCTOPUS_REVIEW_LOGIC_AGENT
if [[ "$(review_agent_for_seat codex implementation-logic-reviewer)" == 'codex' ]]; then
  test_pass
else
  test_fail "unconfigured seat changed upstream default"
fi

test_case "model-qualified CommandCode seats retain provider telemetry identity"
if [[ "$(review_provider_key_from_agent_type "$OCTOPUS_REVIEW_DIVERSITY_AGENT")" == 'commandcode' ]]; then
  test_pass
else
  test_fail "CommandCode review seat was not classified as commandcode"
fi

test_case "model-qualified registry seats omit the model from provider telemetry"
if [[ "$(review_provider_key_from_agent_type 'vibe:provider/model-id')" == 'vibe' ]]; then
  test_pass
else
  test_fail "model-qualified Vibe review seat leaked its model into provider telemetry"
fi

test_summary
