#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Contextual review fleet CLI"

checker="$TEST_TMP_DIR/provider-checker.sh"
cat > "$checker" <<'CHECKER'
#!/usr/bin/env bash
printf '%s\n' \
  'codex:available' \
  'commandcode:available' \
  'claude:available' \
  'agy:available' \
  'openrouter:available' \
  'orcarouter:available' \
  'vibe:available' \
  'atlascloud:available'
CHECKER
chmod +x "$checker"

agy_bin="$TEST_TMP_DIR/agy-bin"
mkdir -p "$agy_bin"
cat > "$agy_bin/agy" <<'AGY'
#!/usr/bin/env bash
if [[ "${1:-}" == "models" ]]; then
  printf '%s\n' 'gemini-exact' 'gemini-known'
  exit 0
fi
exit 1
AGY
chmod +x "$agy_bin/agy"

run_fleet() {
  env -i \
    "HOME=$TEST_TMP_DIR/home" \
    "PATH=$agy_bin:$PATH" \
    "OCTOPUS_PROVIDER_CHECKER=$checker" \
    "OCTO_ALLOWED_PROVIDERS=codex commandcode claude agy openrouter orcarouter vibe atlascloud" \
    "$@" \
    "$PROJECT_ROOT/bin/octopus" fleet review standard target
}

test_case "fleet review shows all eight effective model-qualified seat overrides"
export OCTOPUS_REVIEW_SINGLE_PROVIDER=claude
fleet="$(run_fleet \
  "OCTOPUS_REVIEW_LOGIC_AGENT=openai:gpt-5.6-luna" \
  "OCTOPUS_REVIEW_SECURITY_AGENT=agy:gemini-exact" \
  "OCTOPUS_REVIEW_ARCHITECTURE_AGENT=anthropic:claude-opus-5" \
  "OCTOPUS_REVIEW_CVE_AGENT=command-code:tencent/hy3-paid" \
  "OCTOPUS_REVIEW_DIVERSITY_AGENT=openrouter:deepseek/deepseek-v4" \
  "OCTOPUS_REVIEW_VERIFIER_AGENT=orcarouter:anthropic/claude-sonnet-4.6" \
  "OCTOPUS_REVIEW_DEBATER_AGENT=vibe:mistral-large-latest" \
  "OCTOPUS_REVIEW_SYNTHESIZER_AGENT=atlas-cloud:qwen/qwen3.5")"
unset OCTOPUS_REVIEW_SINGLE_PROVIDER
expected_specs=$'codex:gpt-5.6-luna\nagy:gemini-exact\nclaude:claude-opus-5\ncommandcode:tencent/hy3-paid\nopenrouter:deepseek/deepseek-v4\norcarouter:anthropic/claude-sonnet-4.6\nvibe:mistral-large-latest\natlascloud-agent:qwen/qwen3.5'
actual_specs="$(printf '%s\n' "$fleet" | cut -d'|' -f1)"
if [[ "$(printf '%s\n' "$fleet" | grep -c .)" -eq 8 && "$actual_specs" == "$expected_specs" ]]; then
  test_pass
else
  test_fail "fleet review did not render all effective overrides: $(tr '\n' ';' <<< "$fleet")"
fi

test_case "single-provider override takes precedence and canonicalizes registry aliases"
fleet="$(run_fleet \
  "OCTOPUS_REVIEW_SINGLE_PROVIDER=openai" \
  "OCTOPUS_REVIEW_LOGIC_AGENT=commandcode:model-a" \
  "OCTOPUS_REVIEW_SYNTHESIZER_AGENT=vibe:model-b")"
if [[ "$(printf '%s\n' "$fleet" | grep -c .)" -eq 8 ]] && \
   [[ "$(printf '%s\n' "$fleet" | cut -d'|' -f1 | grep -vc '^codex$' || true)" -eq 0 ]]; then
  test_pass
else
  test_fail "single-provider precedence or canonical identity was not reflected in fleet review: $(tr '\n' ';' <<< "$fleet")"
fi

test_case "fleet review rejects an unavailable single-provider override"
unavailable_rc=0
unavailable_error="$TEST_TMP_DIR/unavailable.err"
unavailable_fleet="$(run_fleet \
  "OCTO_ALLOWED_PROVIDERS=codex commandcode claude agy openrouter orcarouter vibe atlascloud perplexity" \
  "OCTOPUS_REVIEW_SINGLE_PROVIDER=perplexity" 2>"$unavailable_error")" || unavailable_rc=$?
if [[ "$unavailable_rc" -ne 0 && -z "$unavailable_fleet" ]] && \
   grep -Fc "OCTOPUS_REVIEW_SINGLE_PROVIDER 'perplexity' is unavailable" "$unavailable_error" >/dev/null; then
  test_pass
else
  test_fail "unavailable single-provider override escaped admission: rc=$unavailable_rc fleet=[$unavailable_fleet]"
fi

test_case "fleet review rejects an unknown single-provider override"
unknown_rc=0
unknown_error="$TEST_TMP_DIR/unknown.err"
unknown_fleet="$(run_fleet \
  "OCTO_ALLOWED_PROVIDERS=mystery-provider" \
  "OCTOPUS_REVIEW_SINGLE_PROVIDER=mystery-provider" 2>"$unknown_error")" || unknown_rc=$?
if [[ "$unknown_rc" -ne 0 && -z "$unknown_fleet" ]] && \
   grep -Fc "Unknown OCTOPUS_REVIEW_SINGLE_PROVIDER: mystery-provider" "$unknown_error" >/dev/null; then
  test_pass
else
  test_fail "unknown single-provider override escaped registry validation: rc=$unknown_rc fleet=[$unknown_fleet]"
fi

test_case "fleet review rejects a policy-disallowed single-provider override"
disallowed_rc=0
disallowed_error="$TEST_TMP_DIR/disallowed.err"
disallowed_fleet="$(run_fleet \
  "OCTO_ALLOWED_PROVIDERS=agy" \
  "OCTOPUS_REVIEW_SINGLE_PROVIDER=codex" 2>"$disallowed_error")" || disallowed_rc=$?
if [[ "$disallowed_rc" -ne 0 && -z "$disallowed_fleet" ]] && \
   grep -Fc "OCTOPUS_REVIEW_SINGLE_PROVIDER 'codex' is not admitted by the active allowlist" "$disallowed_error" >/dev/null; then
  test_pass
else
  test_fail "policy-disallowed single-provider override escaped admission: rc=$disallowed_rc fleet=[$disallowed_fleet]"
fi

test_case "fleet review rejects an exact model outside the dispatch allowlist"
restricted_rc=0
restricted_error="$TEST_TMP_DIR/restricted.err"
restricted_fleet="$(run_fleet \
  "OCTOPUS_CODEX_ALLOWED_MODELS=gpt-allowed" \
  "OCTOPUS_REVIEW_LOGIC_AGENT=codex:gpt-blocked" 2>"$restricted_error")" || restricted_rc=$?
if [[ "$restricted_rc" -ne 0 && "$restricted_fleet" != *'codex:gpt-blocked'* ]] && \
   grep -Fc "is blocked by the provider model allowlist" "$restricted_error" >/dev/null; then
  test_pass
else
  test_fail "fleet review called a dispatch-rejected model effective: rc=$restricted_rc fleet=[$restricted_fleet]"
fi

test_case "fleet review rejects an exact Fable security seat"
fable_rc=0
fable_error="$TEST_TMP_DIR/fable.err"
fable_fleet="$(run_fleet \
  "OCTOPUS_REVIEW_SECURITY_AGENT=anthropic:claude-fable-5" 2>"$fable_error")" || fable_rc=$?
if [[ "$fable_rc" -ne 0 && "$fable_fleet" != *'claude:claude-fable-5'* ]] && \
   grep -Fc "is unsafe for role 'implementation-security-reviewer'" "$fable_error" >/dev/null; then
  test_pass
else
  test_fail "fleet review called an unsafe Fable security seat effective: rc=$fable_rc fleet=[$fable_fleet]"
fi

test_case "fleet review rejects an AGY model absent from the live catalog"
agy_rc=0
agy_error="$TEST_TMP_DIR/agy-missing-model.err"
agy_fleet="$(run_fleet \
  "OCTOPUS_REVIEW_SECURITY_AGENT=agy:missing-model" 2>"$agy_error")" || agy_rc=$?
if [[ "$agy_rc" -ne 0 && "$agy_fleet" != *'agy:missing-model'* ]] && \
   grep -Fc "is not a valid model for provider 'agy'" "$agy_error" >/dev/null; then
  test_pass
else
  test_fail "fleet review did not clearly reject a dispatch-rejected AGY model: rc=$agy_rc fleet=[$agy_fleet] error=[$(tr '\n' ';' < "$agy_error")]"
fi

test_summary
