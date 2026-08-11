#!/bin/bash
# Qwen/Gemini direct-dispatch guard — blocks bare `qwen "prompt"` and any direct
# `gemini` CLI invocation from Bash, including chained/subshelled forms.
# PreToolUse hook on Bash. Returns block decision with correction message.
# WHY: direct qwen dispatch enters OAuth device authorization and opens a browser;
#      direct gemini dispatch fails with UNSUPPORTED_CLIENT (obsolete individual
#      auth) since the CLI is retired in favor of Antigravity (AGY). Both bypass
#      Octopus's provider availability, auth-expiry, and no-browser admission
#      checks. See issue #860.
set -euo pipefail
# EXIT trap — emits diagnostic stderr ONLY when the hook exits non-zero, so
# the Claude Code harness error "No stderr output" can never recur. EXIT (not
# ERR) avoids over-firing on intermediate `grep -o`/`cmd | ...` inside $() that
# the hook's logic already handles. See issue #313.
_octo_hook_exit() { local c=$?; if [[ $c -ne 0 ]]; then echo "[hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; fi; return 0; }
trap _octo_hook_exit EXIT


# Note: this gate guards correctness/safety (unwanted browser launches, calls to
# a retired CLI), not user permission policy — so it runs regardless of
# bypassPermissions.

INPUT=$(cat 2>/dev/null || true)
[[ -z "$INPUT" ]] && exit 0

# Extract command
if command -v jq &>/dev/null; then
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
else
    COMMAND=$(echo "$INPUT" | grep -o '"command":"[^"]*"' | head -1 | cut -d'"' -f4)
fi
[[ -z "$COMMAND" ]] && exit 0

# Split on command separators/subshell openers so a guarded binary anywhere in a
# chained or subshelled command (e.g. `true && qwen "x"`, `(gemini "x")`,
# `$(qwen "x")`, backticks) is caught — not only a command that starts with it.
NORMALIZED=$(printf '%s\n' "$COMMAND" | sed -E 's/(\|\||&&|;|\|)/\n/g; s/`/\n/g; s/\$\(/\n/g; s/\(/\n/g; s/\)/\n/g')

ALLOWED='--version|-v|--help|-h|help|completion'

blocked=""
while IFS= read -r segment; do
    trimmed=$(echo "$segment" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [[ -z "$trimmed" ]] && continue

    if echo "$trimmed" | grep -qE '^qwen([[:space:]]|$)' && \
       ! echo "$trimmed" | grep -qE "^qwen[[:space:]]+($ALLOWED)([[:space:]]|\$)"; then
        blocked="qwen"
        break
    fi

    if echo "$trimmed" | grep -qE '^gemini([[:space:]]|$)' && \
       ! echo "$trimmed" | grep -qE "^gemini[[:space:]]+($ALLOWED)([[:space:]]|\$)"; then
        blocked="gemini"
        break
    fi
done <<< "$NORMALIZED"

case "$blocked" in
    qwen)
        cat <<'BLOCK'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: direct `qwen` dispatch bypasses Octopus's provider availability, auth-expiry, and no-browser admission checks, and can enter OAuth device authorization that opens a browser.\n\nRoute the request through Octopus instead:\n```bash\nscripts/orchestrate.sh probe-single qwen <perspective> <task_id> \"YOUR PROMPT\"\n```\n\nIntrospection is still allowed: `qwen --version`, `qwen --help`."}}
BLOCK
        exit 0
        ;;
    gemini)
        cat <<'BLOCK'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: the `gemini` CLI is retired — direct dispatch fails with UNSUPPORTED_CLIENT (obsolete individual auth) and bypasses Octopus's admission checks. Google-seat requests route through Antigravity (AGY) instead.\n\nUse Octopus's AGY path:\n```bash\nscripts/orchestrate.sh probe-single agy <perspective> <task_id> \"YOUR PROMPT\"\n```\n\nIntrospection is still allowed: `gemini --version`, `gemini --help`."}}
BLOCK
        exit 0
        ;;
esac

: # pass-through — current hook schema treats silence as continue
