#!/usr/bin/env bash
# Moonshot Kimi Code CLI provider (standalone `kimi` binary).
# No top-level set -e*: sourced libs must not alter parent shell options
# (orchestrate.sh already sets `set -eo pipefail`).
# Auth: selected-provider credentials in $KIMI_CODE_HOME/config.toml (default
# ~/.kimi-code/config.toml), including file-backed OAuth from `kimi login`.
# Headless: current Kimi Code uses -p for non-interactive text output. This mode
# auto-approves tool calls, so routing must limit it to write-capable roles.

_kimi_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${_kimi_lib_dir}/bounded-probe.sh" 2>/dev/null || true
source "${_kimi_lib_dir}/kimi-env.sh" 2>/dev/null || true

_kimi_log(){ if declare -f log >/dev/null 2>&1; then log "$@"; else echo "[${1}] ${*:2}" >&2; fi; }

_kimi_restore_trap(){
    local signal_name="$1" saved_trap="$2"
    if [[ -n "$saved_trap" ]]; then eval "$saved_trap"; else trap - "$signal_name"; fi
}

_kimi_restore_execute_traps(){
    _kimi_restore_trap INT "$1"
    _kimi_restore_trap TERM "$2"
    _kimi_restore_trap HUP "$3"
}

_kimi_signal_status(){
    case "$1" in HUP) echo 129 ;; INT) echo 130 ;; TERM) echo 143 ;; *) echo 1 ;; esac
}

_kimi_cleanup_captures(){
    [[ -z "${response_file:-}" ]] || rm -f "$response_file" 2>/dev/null || true
    [[ -z "${error_file:-}" ]] || rm -f "$error_file" 2>/dev/null || true
    response_file=""
    error_file=""
}

_kimi_handle_execute_signal(){
    local signal_name="$1"
    _kimi_interrupted_status="$(_kimi_signal_status "$signal_name")"
    trap '' TERM INT HUP
    _kimi_cleanup_captures
    _kimi_restore_execute_traps \
        "$_kimi_previous_int_trap" \
        "$_kimi_previous_term_trap" \
        "$_kimi_previous_hup_trap"
    # A direct child sees this shell's real PID as PPID even under Bash 3.2,
    # where $$ does not change in a subshell.
    /bin/sh -c 'kill -s "$1" "$PPID"' kimi-signal "$signal_name"
    return "$_kimi_interrupted_status"
}

# `kimi` is an unambiguous binary name — no identity regex needed (unlike cursor's `agent`).
_is_kimi_binary(){ command -v kimi &>/dev/null; }

kimi_data_root(){
    if [[ -n "${KIMI_CODE_HOME:-}" ]]; then
        printf '%s\n' "$KIMI_CODE_HOME"
    else
        printf '%s\n' "${HOME}/.kimi-code"
    fi
}

kimi_config_file(){
    printf '%s/config.toml\n' "$(kimi_data_root)"
}

_kimi_run_config_check(){
    local binary lib_dir plugin_root helper probe_timeout term_timeout kill_grace
    local -a probe_cmd
    binary="$(command -v kimi 2>/dev/null)" || return 1
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
    plugin_root="$(cd "${lib_dir}/../.." && pwd -P)" || return 1
    helper="${plugin_root}/scripts/helpers/kimi-config-check.mjs"
    [[ -r "$helper" ]] || return 1
    declare -f _octo_bare_probe_timeout >/dev/null 2>&1 || return 1
    declare -f _octo_run_bare_probe_with_timeout >/dev/null 2>&1 || return 1
    declare -f octopus_build_kimi_provider_env >/dev/null 2>&1 || return 1

    read -r probe_timeout term_timeout kill_grace <<< \
        "$(_octo_bare_probe_budget "${OCTOPUS_KIMI_HEALTH_TIMEOUT:-5}")"

    octopus_build_kimi_provider_env
    if [[ ${#KIMI_PROVIDER_ENV_ARRAY[@]} -gt 0 ]]; then
        probe_cmd=(
            "${KIMI_PROVIDER_ENV_ARRAY[@]}"
            "KIMI_PLUGIN_ROOT=$plugin_root"
            "OCTOPUS_KIMI_HEALTH_TIMEOUT_MS=$((probe_timeout * 1000))"
            "$binary" __plugin_run_node "$helper" "$@" "$binary"
        )
    else
        probe_cmd=(
            env
            "KIMI_PLUGIN_ROOT=$plugin_root"
            "OCTOPUS_KIMI_HEALTH_TIMEOUT_MS=$((probe_timeout * 1000))"
            "$binary" __plugin_run_node "$helper" "$@" "$binary"
        )
    fi
    _octo_run_bare_probe_with_timeout \
        "$probe_timeout" "$term_timeout" "$kill_grace" "${probe_cmd[@]}" 2>/dev/null
}

_kimi_config_backend_available(){
    _kimi_run_config_check self-test
}

# Ask Kimi's own doctor to validate the complete TOML document, then emit only
# a credential method label. The plugin runner works in both the native and npm
# distributions, so no ambient Python or Node installation is required.
_kimi_config_credential_record(){
    local config
    config="$(kimi_config_file)"
    [[ -f "$config" || -n "${KIMI_MODEL_NAME:-}" ]] || return 1
    _kimi_run_config_check config-record "$config"
}

_kimi_oauth_file_exists(){
    local storage_name="$1"
    [[ -n "$storage_name" && "$storage_name" != */* && "$storage_name" != .* ]] || return 1
    _kimi_run_config_check oauth-file-valid \
        "$(kimi_data_root)/credentials/${storage_name}.json"
}

kimi_configured_credential_method(){
    local record
    record="$(_kimi_config_credential_record 2>/dev/null)" || return 1
    case "$record" in
        config:api-key) printf '%s\n' "$record" ;;
        oauth-file:*)
            _kimi_oauth_file_exists "${record#oauth-file:}" || return 1
            printf '%s\n' "kimi-session"
            ;;
        oauth-keyring:*)
            # Current Kimi Code uses a file-backed store. A legacy keyring
            # reference alone is not proof of authentication.
            _kimi_oauth_file_exists "${record#oauth-keyring:}" || return 1
            printf '%s\n' "kimi-session"
            ;;
        *) return 1 ;;
    esac
}

kimi_credential_issue(){
    local record
    record="$(_kimi_config_credential_record 2>/dev/null)" || {
        if _kimi_config_backend_available >/dev/null 2>&1; then
            printf '%s\n' "config-invalid"
        else
            printf '%s\n' "validator-unavailable"
        fi
        return 0
    }
    case "$record" in
        model-missing) printf '%s\n' "model-missing" ;;
        vertex-adc-unsupported) printf '%s\n' "$record" ;;
        oauth-keyring:*)
            if ! _kimi_oauth_file_exists "${record#oauth-keyring:}"; then
                printf '%s\n' "keyring-migration-required"
            fi
            ;;
        oauth-file:*)
            if ! _kimi_oauth_file_exists "${record#oauth-file:}"; then
                printf '%s\n' "oauth-invalid"
            fi
            ;;
        none) printf '%s\n' "auth-missing" ;;
    esac
}

# Availability requires an effective model. OCTOPUS_KIMI_MODEL selects a
# configured alias directly; otherwise Kimi resolves top-level default_model.
kimi_has_model(){
    local config
    config="$(kimi_config_file)"
    [[ -f "$config" || -n "${KIMI_MODEL_NAME:-}" ]] || return 1
    _kimi_run_config_check has-model "$config"
}

kimi_is_available(){
    command -v kimi &>/dev/null || return 1
    kimi_configured_credential_method >/dev/null
}

kimi_auth_method(){
    kimi_configured_credential_method 2>/dev/null || printf '%s\n' "none"
}

# kimi_execute AGENT_TYPE PROMPT [OUTFILE] — single-turn headless dispatch.
kimi_execute(){
    local agent_type="$1" prompt="$2" output_file="${3:-}"
    if [[ "$agent_type" != "kimi" ]]; then
        _kimi_log ERROR "kimi: direct execution is limited to the write-capable 'kimi' provider"
        return 1
    fi
    [[ -z "$prompt" && ! -t 0 ]] && prompt="$(cat)"
    command -v kimi &>/dev/null || { _kimi_log ERROR "kimi: CLI not found"; return 1; }
    local timeout="${OCTOPUS_KIMI_TIMEOUT:-150}"
    local model="${OCTOPUS_KIMI_MODEL:-default}"
    local -a cmd=(kimi -p "$prompt")
    local -a execution_cmd
    declare -f octopus_build_kimi_provider_env >/dev/null 2>&1 || {
        _kimi_log ERROR "kimi: environment isolation unavailable"
        return 1
    }
    octopus_build_kimi_provider_env
    [[ -n "$model" && "$model" != "default" ]] && cmd+=(--model "$model")
    if [[ ${#KIMI_PROVIDER_ENV_ARRAY[@]} -gt 0 ]]; then
        execution_cmd=("${KIMI_PROVIDER_ENV_ARRAY[@]}" "${cmd[@]}")
    else
        execution_cmd=("${cmd[@]}")
    fi
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
    local response error_response response_file="" error_file="" exit_code
    local _kimi_previous_int_trap _kimi_previous_term_trap _kimi_previous_hup_trap
    local _kimi_interrupted_status=0
    _kimi_previous_int_trap="$(trap -p INT)"
    _kimi_previous_term_trap="$(trap -p TERM)"
    _kimi_previous_hup_trap="$(trap -p HUP)"
    trap '_kimi_handle_execute_signal INT' INT
    trap '_kimi_handle_execute_signal TERM' TERM
    trap '_kimi_handle_execute_signal HUP' HUP
    response_file="$(umask 077 && mktemp "${TMPDIR:-/tmp}/octo-kimi-response.XXXXXX")" || {
        _kimi_restore_execute_traps "$_kimi_previous_int_trap" "$_kimi_previous_term_trap" "$_kimi_previous_hup_trap"
        _kimi_log ERROR "kimi: could not create response capture"
        return 1
    }
    if [[ "$_kimi_interrupted_status" -ne 0 ]]; then
        _kimi_cleanup_captures
        _kimi_restore_execute_traps "$_kimi_previous_int_trap" "$_kimi_previous_term_trap" "$_kimi_previous_hup_trap"
        return "$_kimi_interrupted_status"
    fi
    error_file="$(umask 077 && mktemp "${TMPDIR:-/tmp}/octo-kimi-error.XXXXXX")" || {
        _kimi_cleanup_captures
        _kimi_restore_execute_traps "$_kimi_previous_int_trap" "$_kimi_previous_term_trap" "$_kimi_previous_hup_trap"
        _kimi_log ERROR "kimi: could not create error capture"
        return 1
    }
    if [[ "$_kimi_interrupted_status" -ne 0 ]]; then
        _kimi_cleanup_captures
        _kimi_restore_execute_traps "$_kimi_previous_int_trap" "$_kimi_previous_term_trap" "$_kimi_previous_hup_trap"
        return "$_kimi_interrupted_status"
    fi
    # Kimi owns private capture files, so its shell must remain able to process
    # INT/TERM while the provider is running. The asynchronous supervisor keeps
    # that contract even on hosts where GNU timeout is installed.
    run_with_timeout --portable-supervisor "$timeout" "${execution_cmd[@]}" >"$response_file" 2>"$error_file" && exit_code=0 || exit_code=$?
    if [[ "$_kimi_interrupted_status" -ne 0 ]]; then
        _kimi_cleanup_captures
        _kimi_restore_execute_traps "$_kimi_previous_int_trap" "$_kimi_previous_term_trap" "$_kimi_previous_hup_trap"
        return "$_kimi_interrupted_status"
    fi
    response="$(< "$response_file")" 2>/dev/null || response=""
    error_response="$(< "$error_file")" 2>/dev/null || error_response=""
    _kimi_cleanup_captures
    _kimi_restore_execute_traps "$_kimi_previous_int_trap" "$_kimi_previous_term_trap" "$_kimi_previous_hup_trap"
    [[ "$_kimi_interrupted_status" -eq 0 ]] || return "$_kimi_interrupted_status"
    if [[ $exit_code -ne 0 ]]; then
        [[ $exit_code -eq 124 ]] && { _kimi_log WARN "kimi: timed out after ${timeout}s"; return 1; }
        if printf '%s\n%s' "$response" "$error_response" | grep -ciE 'unauthorized|forbidden|(401|403)|not authorized|invalid token|expired token|please .?login|login required' >/dev/null; then
            _kimi_log ERROR "kimi: auth failure — run kimi, then enter /login or update $(kimi_config_file)"; return 1
        fi
        _kimi_log ERROR "kimi: exit $exit_code"; return 1
    fi
    [[ -z "$response" ]] && { _kimi_log WARN "kimi: empty response"; return 1; }
    if [[ -n "$output_file" ]]; then printf '%s\n' "$response" > "$output_file"; else printf '%s\n' "$response"; fi
    return 0
}
