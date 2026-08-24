#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Model-aware seats"
cd "$PROJECT_ROOT"

source scripts/lib/agent-spec.sh

test_case "agent spec separates executor and explicit model"
if [[ "$(octo_agent_spec_executor 'commandcode:stealth/ox-alpha')" == commandcode ]] && \
   [[ "$(octo_agent_spec_explicit_model 'commandcode:stealth/ox-alpha')" == stealth/ox-alpha ]]; then test_pass; else test_fail "agent spec parsing mismatch"; fi

test_case "agent spec slug is path-safe"
[[ "$(octo_agent_spec_slug 'commandcode:stealth/ox-alpha')" == commandcode_stealth_ox-alpha ]] && test_pass || test_fail "unexpected slug"

test_case "legacy executor aliases stay intact while provider identity is canonicalized"
if [[ "$(octo_agent_spec_executor 'codex-standard')" == codex-standard ]] && \
   [[ "$(octo_agent_spec_provider 'codex-standard')" == codex ]] && \
   [[ "$(octo_agent_spec_provider 'commandcode:stealth/ox-alpha')" == commandcode ]]; then
  test_pass
else
  test_fail "executor alias and provider identity were conflated"
fi

test_case "model family distinguishes MiniMax and OpenAI"
if [[ "$(octo_model_family 'commandcode:minimaxai/minimax-m3')" == minimax ]] && \
   [[ "$(octo_model_family 'codex:gpt-5.6-luna')" == openai ]]; then test_pass; else test_fail "model family mismatch"; fi

log(){ :; }
PLUGIN_DIR="$PROJECT_ROOT"
source scripts/lib/validation.sh
source scripts/lib/model-resolver.sh
source scripts/lib/dispatch.sh

test_case "model-qualified dispatch preserves CommandCode and Codex pins"
cc_model="$(get_agent_model 'commandcode:stealth/ox-alpha' ceremony code-reviewer)"
codex_model="$(get_agent_model 'codex:gpt-5.6-luna' ceremony code-reviewer)"
cc_cmd="$(get_agent_command 'commandcode:stealth/ox-alpha' ceremony code-reviewer)"
codex_cmd="$(get_agent_command 'codex:gpt-5.6-luna' ceremony code-reviewer)"
if [[ "$cc_model" == stealth/ox-alpha && "$codex_model" == gpt-5.6-luna && "$cc_cmd" == *'commandcode-exec.sh stealth/ox-alpha'* && "$codex_cmd" == *'--model gpt-5.6-luna'* ]]; then test_pass; else test_fail "model-qualified dispatch mismatch"; fi

test_case "review order keeps same-provider model variants and Ox Alpha before Luna"
fake="$TEST_TMP_DIR/provider-check.sh"
cat > "$fake" <<'CHECK'
#!/usr/bin/env bash
echo commandcode:available
echo codex:available
echo claude:available
CHECK
chmod +x "$fake"
order="$(OCTOPUS_PROVIDER_CHECKER="$fake" OCTOPUS_COUNCIL_DEFAULT_PROVIDERS='commandcode:stealth/ox-alpha,commandcode:minimaxai/minimax-m3,commandcode:deepseek/deepseek-v4-flash,codex:gpt-5.6-luna,codex:gpt-5.6-sol' bash scripts/helpers/build-fleet.sh review-order standard test)"
ox_line="$(printf '%s\n' "$order" | grep -n -F 'commandcode:stealth/ox-alpha' | head -1 | cut -d: -f1)"
luna_line="$(printf '%s\n' "$order" | grep -n -F 'codex:gpt-5.6-luna' | head -1 | cut -d: -f1)"
all_present=true
for spec in 'commandcode:stealth/ox-alpha' 'commandcode:minimaxai/minimax-m3' 'commandcode:deepseek/deepseek-v4-flash' 'codex:gpt-5.6-luna' 'codex:gpt-5.6-sol'; do
  printf '%s\n' "$order" | grep -Fxq "$spec" || all_present=false
done
if [[ "$all_present" == true && -n "$ox_line" && -n "$luna_line" && "$ox_line" -lt "$luna_line" ]]; then test_pass; else test_fail "review order mismatch"; fi

source scripts/lib/council.sh
council_prompt_for_member(){ echo prompt; }
council_persona_should_fail(){ return 1; }
run_quorum_case(){
  local roster="$1" d
  d="$TEST_TMP_DIR/quorum-$RANDOM"
  mkdir -p "$d/responses"
  COUNCIL_RUN_DIR="$d"
  COUNCIL_DEPTH=standard
  COUNCIL_FIXTURE=full-success
  COUNCIL_EXECUTION_MODE=""
  COUNCIL_TASK=x
  COUNCIL_GOAL=advice
  COUNCIL_DOMAIN=auto
  COUNCIL_STYLE=balanced
  COUNCIL_ROSTER_JSON="$roster"
  council_run_advice_phase >/dev/null 2>&1 || true
}

test_case "same provider with different model families contributes independent quorum"
case_a='[{"persona":"strategy-analyst","seat":"chair","agent_spec":"claude-sonnet","provider":"claude-sonnet","provider_org":"anthropic","model":"claude-sonnet-5","model_family":"anthropic"},{"persona":"code-reviewer","seat":"member","agent_spec":"commandcode:minimaxai/minimax-m3","provider":"commandcode","provider_org":"commandcode","model":"minimaxai/minimax-m3","model_family":"minimax"},{"persona":"backend-architect","seat":"member","agent_spec":"commandcode:deepseek/deepseek-v4-flash","provider":"commandcode","provider_org":"commandcode","model":"deepseek/deepseek-v4-flash","model_family":"deepseek"}]'
run_quorum_case "$case_a"
if [[ "$COUNCIL_QUORUM_MET" == true && "$COUNCIL_DISTINCT_APPROVING_MODEL_FAMILIES" == 2 && "$COUNCIL_DISTINCT_APPROVING_PROVIDERS" == 1 ]]; then test_pass; else test_fail "same-provider family quorum mismatch"; fi

test_case "different providers with one model family do not create false independence"
case_b='[{"persona":"strategy-analyst","seat":"chair","agent_spec":"claude-sonnet","provider":"claude-sonnet","provider_org":"anthropic","model":"claude-sonnet-5","model_family":"anthropic"},{"persona":"code-reviewer","seat":"member","agent_spec":"commandcode:openai/gpt-5","provider":"commandcode","provider_org":"commandcode","model":"openai/gpt-5","model_family":"openai"},{"persona":"backend-architect","seat":"member","agent_spec":"codex:gpt-5.6-luna","provider":"codex","provider_org":"openai","model":"gpt-5.6-luna","model_family":"openai"}]'
run_quorum_case "$case_b"
if [[ "$COUNCIL_QUORUM_MET" == false && "$COUNCIL_DISTINCT_APPROVING_MODEL_FAMILIES" == 1 && "$COUNCIL_DISTINCT_APPROVING_PROVIDERS" == 2 ]]; then test_pass; else test_fail "same-family quorum mismatch"; fi


test_case "model-qualified large-context Codex keeps the large context budget"
OCTOPUS_CONTEXT_BUDGET=12000
OCTOPUS_CODEX_CONTEXT_BUDGET=24000
OCTOPUS_CODEX_LARGE_CONTEXT_BUDGET=77777
if [[ "$(get_provider_context_limit 'codex-large-context:gpt-5')" == 77777 ]]; then
  test_pass
else
  test_fail "qualified codex-large-context lost its special budget"
fi

test_case "Council provider status canonicalizes model-qualified provider keys"
COUNCIL_PROVIDERS='commandcode:stealth/ox-alpha'
OCTOPUS_COUNCIL_PROVIDER_FIXTURE='commandcode:stealth/ox-alpha:available'
council_detect_providers
if [[ "$(jq -r '.commandcode // "missing"' <<< "$COUNCIL_PROVIDER_STATUS_JSON")" == available ]] && \
   [[ "$(jq -r 'has("commandcode:stealth/ox-alpha")' <<< "$COUNCIL_PROVIDER_STATUS_JSON")" == false ]] && \
   council_provider_is_available 'commandcode:stealth/ox-alpha'; then
  test_pass
else
  test_fail "provider status map was not canonicalized: $COUNCIL_PROVIDER_STATUS_JSON"
fi
unset OCTOPUS_COUNCIL_PROVIDER_FIXTURE

test_summary
