#!/usr/bin/env bash
# Moonshot Kimi Code CLI provider (standalone `kimi` binary).
# No top-level set -e*: sourced libs must not alter parent shell options
# (orchestrate.sh already sets `set -eo pipefail`).
# Auth: $MOONSHOT_API_KEY or ~/.kimi-code/credentials/kimi-code.json (kimi login).
# Headless: kimi -p "<prompt>" --output-format text  (single-turn, prints+exits).
# Config errors (no model / unknown alias) exit 1, so the exit-code check below
# is the whole contract — no stdout scanning needed. Verified on kimi 0.39.1.

_kimi_log(){ if declare -f log >/dev/null 2>&1; then log "$@"; else echo "[${1}] ${*:2}" >&2; fi; }

_kimi_run_with_timeout(){
    local t="$1"; shift
    if command -v gtimeout &>/dev/null; then gtimeout "$t" "$@"; return $?; fi
    if command -v timeout  &>/dev/null; then timeout  "$t" "$@"; return $?; fi
    "$@"
}

# `kimi` is an unambiguous binary name — no identity regex needed (unlike cursor's `agent`).
_is_kimi_binary(){ command -v kimi &>/dev/null; }

# A signed-in kimi with no configured provider refuses every prompt, so a model
# is part of the availability contract, not a nicety. Readiness must be proven by
# kimi's OWN config.toml: an octo-side pin is not sufficient on its own, because
# kimi resolves -m against its config and otherwise fails with
#   Model "<alias>" is not configured in config.toml.
# So a pin only counts when config.toml actually declares that alias.
kimi_has_model(){
    local config="${HOME}/.kimi-code/config.toml"
    [[ -f "$config" ]] || return 1
    local pinned="${OCTOPUS_KIMI_MODEL:-}"
    if [[ -n "$pinned" && "$pinned" != "default" ]]; then
        grep -Fq -- "$pinned" "$config"
        return $?
    fi
    grep -Eq '^[[:space:]]*default_model[[:space:]]*=' "$config"
}

kimi_is_available(){
    command -v kimi &>/dev/null || return 1
    # Recover MOONSHOT_API_KEY from the shell profile in non-interactive runs
    # (mirrors codex/grok/vibe) so fleet, health, and discovery agree.
    if [[ -z "${MOONSHOT_API_KEY:-}" ]] && declare -f resolve_provider_env >/dev/null 2>&1; then
        resolve_provider_env "MOONSHOT_API_KEY" 2>/dev/null || true
    fi
    [[ -n "${MOONSHOT_API_KEY:-}" ]] || [[ -f "${HOME}/.kimi-code/credentials/kimi-code.json" ]] || return 1
    kimi_has_model
}

kimi_auth_method(){
    local auth="none"
    if   [[ -n "${MOONSHOT_API_KEY:-}" ]];                                then auth="env:MOONSHOT_API_KEY"
    elif [[ -f "${HOME}/.kimi-code/credentials/kimi-code.json" ]];        then auth="kimi-session"
    fi
    # Signed in but unusable is its own state — callers must not treat it as ready.
    if [[ "$auth" != "none" ]] && ! kimi_has_model; then
        auth="${auth}-no-model"
    fi
    echo "$auth"
}

# kimi_execute AGENT_TYPE PROMPT [OUTFILE] — single-turn headless dispatch.
kimi_execute(){
    local agent_type="$1" prompt="$2" output_file="${3:-}"
    [[ -z "$prompt" && ! -t 0 ]] && prompt="$(cat)"
    command -v kimi &>/dev/null || { _kimi_log ERROR "kimi: CLI not found"; return 1; }
    local timeout="${OCTOPUS_KIMI_TIMEOUT:-150}"
    local model="${OCTOPUS_KIMI_MODEL:-default}"
    local -a cmd=(kimi -p "$prompt" --output-format text --auto)
    [[ -n "$model" && "$model" != "default" ]] && cmd+=(--model "$model")
    local response exit_code
    response=$(_kimi_run_with_timeout "$timeout" "${cmd[@]}" 2>/dev/null) && exit_code=0 || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        [[ $exit_code -eq 124 ]] && { _kimi_log WARN "kimi: timed out after ${timeout}s"; return 1; }
        if printf '%s' "$response" | grep -ciE 'unauthorized|forbidden|(401|403)|not authorized|invalid token|expired token|please .?login|login required' >/dev/null; then
            _kimi_log ERROR "kimi: auth failure — run: kimi login (or set MOONSHOT_API_KEY)"; return 1
        fi
        _kimi_log ERROR "kimi: exit $exit_code"; return 1
    fi
    [[ -z "$response" ]] && { _kimi_log WARN "kimi: empty response"; return 1; }
    if [[ -n "$output_file" ]]; then printf '%s\n' "$response" > "$output_file"; else printf '%s\n' "$response"; fi
    return 0
}
