#!/usr/bin/env bash
# Every provider's emitted dispatch command must survive validation (#750).
#
# validate_agent_command has been asserted shim-by-shim: a test names one shim,
# checks it is allowed, and the next provider added to dispatch has no such
# test. That has failed four times in one cycle, each time silently, each time
# only discovered when a user's dispatch aborted with "Invalid agent command":
#
#   #696  commandcode   rejected by the model-config whitelist
#   #697  copilot       copilot-exec.sh missing from the shim allowlist
#   #705  agy           agy-exec.sh missing from the shim allowlist
#   #769  grok          grok-exec.sh missing, plus the env-prefixed form
#         claude-sdk    claude-sdk-exec.sh missing, same
#
# This suite closes the loop by deriving its work list from the provider
# registry rather than a hand-kept list, so a provider added to the registry is
# covered here the moment it exists.
#
# Design note, learned by getting it wrong first. The obvious version of this
# test iterates the shim files in scripts/helpers/ and asserts each path
# validates. That produces false failures: dispatch never emits a bare
# gemini-exec.sh path, only `env NODE_NO_WARNINGS=1 .../gemini-exec.sh <model>`,
# and the bare path is correctly rejected. The command that matters is the one
# get_agent_command actually emits, so that is what this asserts.
set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Dispatch command round-trip (#750)"

# dispatch.sh reaches model-resolver.sh and provider-routing.sh at call time;
# without them get_agent_command returns empty for every provider and the whole
# suite would pass vacuously. The count guard below is what catches that.
export _BARE_OPT="${_BARE_OPT:-}"
export OCTOPUS_PLATFORM="${OCTOPUS_PLATFORM:-Linux}"
export PLUGIN_DIR="${PLUGIN_DIR:-$PROJECT_ROOT}"
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$PROJECT_ROOT}"

for _lib in provider-registry utils model-resolver provider-routing dispatch; do
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/scripts/lib/${_lib}.sh" 2>/dev/null || true
done

test_case "the dispatch and validation entry points are loaded"
if declare -f get_agent_command >/dev/null 2>&1 &&
   declare -f validate_agent_command >/dev/null 2>&1 &&
   declare -f octo_provider_ids >/dev/null 2>&1; then
    test_pass
else
    test_fail "get_agent_command, validate_agent_command or octo_provider_ids is undefined — the suite cannot judge anything"
fi

# Derived from the registry (#762), not hardcoded. A provider registered on the
# model-config surface is dispatched from it, so that is the right work list.
# octo_provider_ids emits a single space-separated line; normalise to one per
# line here so every consumer below can read it the same way. Reading it as
# newline-delimited treats the whole roster as one provider name, which yields
# an empty command for it and a silently vacuous pass.
providers="$(octo_provider_ids model-config 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true)"

test_case "the provider registry yields a work list"
provider_count="$(printf '%s\n' "$providers" | grep -c . || true)"
if [[ "${provider_count:-0}" -ge 10 ]]; then
    test_pass
else
    test_fail "registry returned ${provider_count} providers — expected at least 10, so every assertion below would be near-vacuous"
fi

# The assertion. Each provider's *emitted* command must validate.
#
# Providers whose command is empty are recorded, not failed: several
# (atlascloud, the openai-compatible family) resolve a model only when their
# API key or config is present, and CI has neither. An empty command is not a
# dispatch that would be rejected — it is a provider that never dispatches.
# The emitted count is asserted separately so this cannot pass by emitting
# nothing at all.
rejected=""
emitted=0
skipped=""
while IFS= read -r provider; do
    [[ -n "$provider" ]] || continue
    cmd="$(get_agent_command "$provider" probe researcher 2>/dev/null || true)"
    if [[ -z "$cmd" ]]; then
        skipped="$skipped $provider"
        continue
    fi
    emitted=$((emitted + 1))
    if ! validate_agent_command "$cmd" >/dev/null 2>&1; then
        rejected="$rejected ${provider}"
    fi
done < <(printf '%s\n' "$providers")

test_case "every emitted dispatch command passes validate_agent_command"
if [[ -z "$rejected" ]]; then
    test_pass
else
    test_fail "dispatch emits commands that validation rejects, so these providers abort before their CLI runs:${rejected} — add the shape to validate_agent_command's allowlist (see #769)"
fi

# Guards a vacuous pass: if model resolution breaks, every command would be
# empty and the assertion above would be trivially satisfied.
test_case "most registered providers actually emit a command"
if [[ "$emitted" -ge 10 ]]; then
    test_pass
else
    test_fail "only ${emitted} of ${provider_count} providers emitted a command (skipped:${skipped:-none}) — model resolution is probably broken, which would make the round-trip assertion vacuous"
fi

# The specific regressions this suite exists to prevent, pinned by name. If the
# derivation above ever stops covering them, these still fail.
test_case "the four providers with a history of silent rejection are covered"
missing=""
for provider in commandcode copilot agy grok; do
    printf '%s\n' "$providers" | grep -qx "$provider" || missing="$missing $provider"
done
if [[ -z "$missing" ]]; then
    test_pass
else
    test_fail "registry no longer lists:${missing} — #696, #697, #705 and #769 would go uncovered"
fi

# A validator that accepts everything would make all of the above meaningless.
test_case "validate_agent_command still rejects a command it should"
if validate_agent_command "/tmp/definitely-not-a-shim.sh --pwn" >/dev/null 2>&1; then
    test_fail "validation accepted an arbitrary path — the assertions above prove nothing"
else
    test_pass
fi

test_summary
