#!/usr/bin/env bash
# Moonshot Kimi Code CLI provider (standalone `kimi` binary).
# No top-level set -e*: sourced libs must not alter parent shell options
# (orchestrate.sh already sets `set -eo pipefail`).
# Auth: $MOONSHOT_API_KEY or ~/.kimi-code/credentials/kimi-code.json (kimi login).
# Headless: kimi -p "<prompt>" --output-format text  (single-turn, prints+exits).
# NB: --auto is mutually exclusive with -p ("Cannot combine --prompt with --auto").
# Config errors (no model / unknown alias) exit 1, so the exit-code check below
# is the whole contract — no stdout scanning needed. Verified on kimi 0.39.1.

_kimi_log(){ if declare -f log >/dev/null 2>&1; then log "$@"; else echo "[${1}] ${*:2}" >&2; fi; }

# `kimi` is an unambiguous binary name — no identity regex needed (unlike cursor's `agent`).
_is_kimi_binary(){ command -v kimi &>/dev/null; }

# A signed-in kimi with no configured provider refuses every prompt, so a model
# is part of the availability contract, not a nicety.
#
# kimi reads the pointer as a TOP-LEVEL key only (`config.raw["default_model"]`),
# and `[secondary_model]` carries its own `default_model` for the subagent pool.
# A line-anchored grep therefore reports ready for a config that has only a
# subagent model and no main one. So the scan stops at the first table header.
#
# The value matters too: `default_model = ""` or a bare `=` is not a model, and
# kimi fails resolution on it exactly as if the key were absent.
#
# Not verified here: that the pointer names a live `[models."<alias>"]` entry
# with reachable provider credentials — kimi's own gate does check that, but it
# needs the parsed config. A stale pointer costs one dispatch that exits
# non-zero with a clear message, which spawn.sh already treats as a failure.
# `kimi provider list --json` would be authoritative but costs ~1.4s a call,
# far too slow for a path that runs per provider on every detection.
#
# OCTOPUS_KIMI_MODEL deliberately does not count: kimi resolves -m against this
# same config, so a pin with no matching alias fails just as hard.
kimi_has_model(){
    local config="${HOME}/.kimi-code/config.toml"
    [[ -f "$config" ]] || return 1
    awk '
        # Stop at the first table header: past it we are no longer top-level.
        /^[[:space:]]*\[/ { stop = 1 }
        !stop && /^[[:space:]]*default_model[[:space:]]*=/ {
            value = $0
            sub(/^[[:space:]]*default_model[[:space:]]*=[[:space:]]*/, "", value)
            sub(/[[:space:]]*#.*$/, "", value)
            gsub(/^["'"'"']|["'"'"']$/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (length(value) > 0) { found = 1 }
        }
        END { exit(found ? 0 : 1) }
    ' "$config"
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
    local -a cmd=(kimi -p "$prompt" --output-format text)
    [[ -n "$model" && "$model" != "default" ]] && cmd+=(--model "$model")
    # Normal dispatch is already bounded by spawn.sh. Direct callers can source
    # kimi.sh on its own, so load that same portable watchdog on demand rather
    # than maintaining a second provider-specific timeout implementation.
    if ! declare -f run_with_timeout >/dev/null 2>&1; then
        local kimi_lib_dir
        kimi_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || {
            _kimi_log ERROR "kimi: shared timeout unavailable"
            return 1
        }
        source "${kimi_lib_dir}/heartbeat.sh" 2>/dev/null || {
            _kimi_log ERROR "kimi: shared timeout unavailable"
            return 1
        }
    fi
    # File-backed capture prevents a provider descendant from keeping command
    # substitution open after the main process has exited.
    local response error_response response_file error_file exit_code
    response_file="$(umask 077 && mktemp "${TMPDIR:-/tmp}/octo-kimi-response.XXXXXX")" || {
        _kimi_log ERROR "kimi: could not create response capture"
        return 1
    }
    error_file="$(umask 077 && mktemp "${TMPDIR:-/tmp}/octo-kimi-error.XXXXXX")" || {
        rm -f "$response_file"
        _kimi_log ERROR "kimi: could not create error capture"
        return 1
    }
    run_with_timeout "$timeout" "${cmd[@]}" >"$response_file" 2>"$error_file" && exit_code=0 || exit_code=$?
    response="$(< "$response_file")"
    error_response="$(< "$error_file")"
    rm -f "$response_file" "$error_file"
    if [[ $exit_code -ne 0 ]]; then
        [[ $exit_code -eq 124 ]] && { _kimi_log WARN "kimi: timed out after ${timeout}s"; return 1; }
        if printf '%s\n%s' "$response" "$error_response" | grep -ciE 'unauthorized|forbidden|(401|403)|not authorized|invalid token|expired token|please .?login|login required' >/dev/null; then
            _kimi_log ERROR "kimi: auth failure — run: kimi login (or set MOONSHOT_API_KEY)"; return 1
        fi
        _kimi_log ERROR "kimi: exit $exit_code"; return 1
    fi
    [[ -z "$response" ]] && { _kimi_log WARN "kimi: empty response"; return 1; }
    if [[ -n "$output_file" ]]; then printf '%s\n' "$response" > "$output_file"; else printf '%s\n' "$response"; fi
    return 0
}
