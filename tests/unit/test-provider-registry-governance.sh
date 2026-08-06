#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
source "$PROJECT_ROOT/scripts/lib/provider-registry.sh"
source "$PROJECT_ROOT/scripts/lib/provider-policy.sh"

test_suite "Provider registry governance contracts"

BASE_ROWS="$(octo_provider_registry_rows)"
BASE_LIMITATIONS="$(octo_provider_limitations_rows)"

restore_registry() {
    octo_provider_registry_rows() { printf '%s\n' "$BASE_ROWS"; }
    octo_provider_limitations_rows() { printf '%s\n' "$BASE_LIMITATIONS"; }
}

test_case "all registered providers satisfy the universal baseline"
if octo_provider_validate_contracts; then test_pass; else test_fail "baseline contract validation failed"; fi

test_case "removing a baseline capability fails validation"
MUTATED_ROWS="$(printf '%s\n' "$BASE_ROWS" | sed 's/vibe||vibe|mistral|model-config,health,detect,dispatch,env/vibe||vibe|mistral|model-config,health,detect,dispatch/')"
octo_provider_registry_rows() { printf '%s\n' "$MUTATED_ROWS"; }
if octo_provider_validate_contracts >/dev/null 2>&1; then test_fail "missing env baseline was accepted"; else test_pass; fi
restore_registry

test_case "every omitted optional capability needs an explicit limitation"
MUTATED_LIMITATIONS="$(printf '%s\n' "$BASE_LIMITATIONS" | grep -v '^vibe|council|')"
octo_provider_limitations_rows() { printf '%s\n' "$MUTATED_LIMITATIONS"; }
if octo_provider_validate_contracts >/dev/null 2>&1; then test_fail "undocumented Council omission was accepted"; else test_pass; fi
restore_registry

test_case "a limitation cannot contradict a declared capability"
MUTATED_LIMITATIONS="${BASE_LIMITATIONS}
codex|council|contradictory-test-limitation"
octo_provider_limitations_rows() { printf '%s\n' "$MUTATED_LIMITATIONS"; }
if octo_provider_validate_contracts >/dev/null 2>&1; then test_fail "contradictory limitation was accepted"; else test_pass; fi
restore_registry

test_case "limitations cannot reference unknown providers"
MUTATED_LIMITATIONS="${BASE_LIMITATIONS}
unknown-provider|council|invalid-provider"
octo_provider_limitations_rows() { printf '%s\n' "$MUTATED_LIMITATIONS"; }
if octo_provider_validate_contracts >/dev/null 2>&1; then test_fail "unknown limitation provider was accepted"; else test_pass; fi
restore_registry

test_case "Council policy rejects unknown providers"
if OCTOPUS_COUNCIL_DEFAULT_PROVIDERS="claude,unknown-provider" octo_council_default_providers >/dev/null 2>&1; then
    test_fail "unknown Council provider was accepted"
else
    test_pass
fi

test_case "Council policy rejects providers without Council capability and reports reason"
set +e
policy_error=$(OCTOPUS_COUNCIL_DEFAULT_PROVIDERS="claude-sdk" octo_council_default_providers 2>&1)
policy_rc=$?
set -e
if [[ "$policy_rc" -eq 2 && "$policy_error" == *"sdk-agent-runtime-is-not-a-supported-council-seat"* ]]; then
    test_pass
else
    test_fail "unsupported Council provider was not rejected with its limitation: rc=$policy_rc error=$policy_error"
fi

test_case "policy rejects canonical duplicates introduced through aliases"
if OCTOPUS_COUNCIL_DEFAULT_PROVIDERS="commandcode,command-code" octo_council_default_providers >/dev/null 2>&1; then
    test_fail "duplicate canonical provider was accepted"
else
    test_pass
fi

test_case "policy rejects empty entries"
if OCTOPUS_COUNCIL_DEFAULT_PROVIDERS="claude,,codex" octo_council_default_providers >/dev/null 2>&1; then
    test_fail "empty provider entry was accepted"
else
    test_pass
fi

test_case "Smoke routing policy rejects unknown providers"
if OCTOPUS_SMOKE_ROUTING_PROVIDERS="codex unknown-provider" octo_smoke_routing_providers >/dev/null 2>&1; then
    test_fail "unknown smoke provider was accepted"
else
    test_pass
fi

test_case "Council command fails early when its configured default policy is invalid"
set +e
command_output=$(OCTOPUS_COUNCIL_DEFAULT_PROVIDERS="claude-sdk" bash -c '
  source "'$PROJECT_ROOT'/scripts/lib/council.sh"
  council_validate_provider_list auto
' 2>&1)
command_rc=$?
set -e
if [[ "$command_rc" -eq 2 && "$command_output" == *"invalid OCTOPUS_COUNCIL_DEFAULT_PROVIDERS policy"* ]]; then
    test_pass
else
    test_fail "Council did not fail early for invalid policy: rc=$command_rc output=$command_output"
fi

test_summary
