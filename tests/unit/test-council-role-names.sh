#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Council role namespacing"

log() { :; }
source "$PROJECT_ROOT/scripts/lib/dispatch.sh"
source "$PROJECT_ROOT/scripts/lib/review.sh"

test_case "design council roles keep legacy persona semantics"
if [[ "$(octo_persona_role design-feasibility-reviewer)" == implementer ]] && \
   [[ "$(octo_persona_role design-research-reviewer)" == researcher ]] && \
   [[ "$(octo_persona_role design-code-reviewer)" == code-reviewer ]] && \
   [[ "$(octo_persona_role design-synthesizer)" == synthesizer ]]; then
    test_pass
else
    test_fail "design council persona aliases changed behavior"
fi

test_case "implementation council roles keep legacy persona semantics"
if [[ "$(octo_persona_role implementation-logic-reviewer)" == logic-reviewer ]] && \
   [[ "$(octo_persona_role implementation-security-reviewer)" == security-reviewer ]] && \
   [[ "$(octo_persona_role implementation-architecture-reviewer)" == arch-reviewer ]] && \
   [[ "$(octo_persona_role implementation-cve-reviewer)" == cve-reviewer ]] && \
   [[ "$(octo_persona_role implementation-diversity-reviewer)" == reviewer ]] && \
   [[ "$(octo_persona_role implementation-verifier)" == code-reviewer ]] && \
   [[ "$(octo_persona_role implementation-debater)" == code-reviewer ]] && \
   [[ "$(octo_persona_role implementation-synthesizer)" == code-reviewer ]]; then
    test_pass
else
    test_fail "implementation council persona aliases changed behavior"
fi

test_case "implementation review fleet uses namespaced roles"
review_file="$PROJECT_ROOT/scripts/lib/review.sh"
if grep -Fq ':implementation-logic-reviewer:' "$review_file" && \
   grep -Fq ':implementation-security-reviewer:' "$review_file" && \
   grep -Fq ':implementation-architecture-reviewer:' "$review_file" && \
   grep -Fq ':implementation-cve-reviewer:' "$review_file" && \
   grep -Fq ':implementation-diversity-reviewer:' "$review_file" && \
   grep -Fq '"implementation-verifier" "review"' "$review_file" && \
   grep -Fq '"implementation-debater" "review"' "$review_file" && \
   grep -Fq '"implementation-synthesizer" "review"' "$review_file"; then
    test_pass
else
    test_fail "implementation review still reuses execution-role names"
fi


test_case "Round 1 finding events preserve namespaced council role"
review_file="$PROJECT_ROOT/scripts/lib/review.sh"
if grep -Fq 'get_agent_model "$atype" "review" "${round1_roles[$idx]}"' "$review_file" && \
   grep -Fq 'role="${round1_roles[$idx]}" severity=' "$review_file"; then
    test_pass
else
    test_fail "Round 1 finding event still collapses role to generic reviewer"
fi

test_case "suffixed OpenAI-compatible participants stay in the configured review fleet"
fleet_home="$TEST_TMP_DIR/openai-compatible-agent-prefix"
mkdir -p "$fleet_home/.claude-octopus/config"
cat > "$fleet_home/.claude-octopus/config/providers.json" <<'EOF'
{
  "routing": {
    "features": {
      "review": ["openai-compatible-agent-custom"]
    }
  }
}
EOF
configured_fleet="$(HOME="$fleet_home" _review_fleet_from_config)"
if grep -Fq 'openai-compatible-agent-custom:implementation-logic-reviewer:' <<< "$configured_fleet"; then
    test_pass
else
    test_fail "suffixed OpenAI-compatible participant was dropped: $configured_fleet"
fi

test_summary
