#!/usr/bin/env bash
# Moonshot Kimi Code CLI provider (standalone `kimi` binary).
# No top-level set -e*: sourced libs must not alter parent shell options
# (orchestrate.sh already sets `set -eo pipefail`).
# Auth: selected-provider credentials in $KIMI_CODE_HOME/config.toml (default
# ~/.kimi-code/config.toml), including file-backed OAuth from `kimi login`.
# Headless: kimi -p "<prompt>" --output-format text  (single-turn, prints+exits).
# NB: --auto is mutually exclusive with -p ("Cannot combine --prompt with --auto").
# Config errors (no model / unknown alias) exit 1, so the exit-code check below
# is the whole contract — no stdout scanning needed. Verified on Kimi Code 0.40.1.

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

# Parse only the credential-bearing subset of Kimi Code's TOML contract. The
# parser follows default_model -> models.<alias>.provider -> providers.<name>
# and emits a method label, never a credential value. Unsupported TOML shapes
# fail closed and are left to the CLI's actionable startup diagnostics.
_kimi_config_credential_record(){
    local config
    config="$(kimi_config_file)"
    [[ -f "$config" ]] || return 1

    awk '
        function trim(value) {
            sub(/^[ \t\r\n]+/, "", value)
            sub(/[ \t\r\n]+$/, "", value)
            return value
        }
        function string_value(line, value, quote, i, char, escaped, tail) {
            string_ok = 0
            sub(/^[^=]*=/, "", line)
            value = trim(line)
            quote = substr(value, 1, 1)
            if (quote != "\"" && quote != "\047") return ""
            escaped = 0
            for (i = 2; i <= length(value); i++) {
                char = substr(value, i, 1)
                if (quote == "\"" && char == "\\" && !escaped) {
                    escaped = 1
                    continue
                }
                if (char == quote && !escaped) {
                    tail = trim(substr(value, i + 1))
                    if (tail != "" && substr(tail, 1, 1) != "#") return ""
                    string_ok = 1
                    return substr(value, 2, i - 2)
                }
                escaped = 0
            }
            return ""
        }
        function positive_integer(line, value) {
            integer_ok = 0
            sub(/^[^=]*=/, "", line)
            value = trim(line)
            sub(/[ \t]+#.*/, "", value)
            value = trim(value)
            if (value !~ /^[0-9]+$/ || value + 0 < 1) return ""
            integer_ok = 1
            return value
        }
        function first_component(value, rest, end) {
            rest = trim(value)
            if (substr(rest, 1, 1) == "\"") {
                rest = substr(rest, 2)
                end = index(rest, "\"")
                if (end == 0) return ""
                return substr(rest, 1, end - 1)
            }
            sub(/\..*$/, "", rest)
            return rest
        }
        function component_suffix(value, rest, end) {
            rest = trim(value)
            if (substr(rest, 1, 1) == "\"") {
                rest = substr(rest, 2)
                end = index(rest, "\"")
                if (end == 0) return "invalid"
                rest = substr(rest, end + 1)
            } else {
                sub(/^[^.]+/, "", rest)
            }
            sub(/^\./, "", rest)
            return rest
        }
        /^[ \t]*#/ || /^[ \t]*$/ { next }
        /^[ \t]*\[\[/ {
            header = trim($0)
            if (header !~ /^\[\[[^]]+\]\][ \t]*(#.*)?$/) invalid = 1
            kind = "other"; name = ""; suffix = ""
            next
        }
        /^[ \t]*\[/ {
            header = trim($0)
            if (header !~ /^\[[^]]+\][ \t]*(#.*)?$/) { invalid = 1; next }
            sub(/^\[/, "", header)
            sub(/\][ \t]*(#.*)?$/, "", header)
            if (table_seen[header]++) invalid = 1
            kind = "other"; name = ""; suffix = ""
            if (index(header, "models.") == 1) {
                rest = substr(header, 8)
                kind = "model"
                name = first_component(rest)
                suffix = component_suffix(rest)
            } else if (index(header, "providers.") == 1) {
                rest = substr(header, 11)
                kind = "provider"
                name = first_component(rest)
                suffix = component_suffix(rest)
            }
            next
        }
        kind == "" && /^[ \t]*default_model[ \t]*=/ {
            if (default_seen++) invalid = 1
            default_model = string_value($0)
            if (!string_ok || default_model == "") invalid = 1
            next
        }
        kind == "model" && suffix == "" && /^[ \t]*provider[ \t]*=/ {
            if (model_provider_seen[name]++) invalid = 1
            model_provider[name] = string_value($0)
            if (!string_ok || model_provider[name] == "") invalid = 1
            next
        }
        kind == "model" && suffix == "" && /^[ \t]*model[ \t]*=/ {
            if (model_id_seen[name]++) invalid = 1
            model_id[name] = string_value($0)
            if (!string_ok || model_id[name] == "") invalid = 1
            next
        }
        kind == "model" && suffix == "" && /^[ \t]*max_context_size[ \t]*=/ {
            if (model_context_seen[name]++) invalid = 1
            model_context[name] = positive_integer($0)
            if (!integer_ok) invalid = 1
            next
        }
        kind == "provider" && suffix == "" && /^[ \t]*type[ \t]*=/ {
            if (provider_type_seen[name]++) invalid = 1
            provider_type[name] = string_value($0)
            if (!string_ok || provider_type[name] == "") invalid = 1
            next
        }
        kind == "provider" && suffix == "" && /^[ \t]*api_key[ \t]*=/ {
            if (direct_key_seen[name]++) invalid = 1
            value = string_value($0)
            if (!string_ok) invalid = 1
            if (value != "") direct_key[name] = 1
            next
        }
        kind == "provider" && suffix == "env" && /^[ \t]*[A-Za-z_][A-Za-z0-9_]*_API_KEY[ \t]*=/ {
            key = $0
            sub(/^[ \t]*/, "", key)
            sub(/[ \t]*=.*/, "", key)
            if (env_key_seen[name, key]++) invalid = 1
            value = string_value($0)
            if (!string_ok) invalid = 1
            if (value != "") env_key[name, key] = 1
            next
        }
        kind == "provider" && suffix == "oauth" && /^[ \t]*storage[ \t]*=/ {
            if (oauth_storage_seen[name]++) invalid = 1
            oauth_storage[name] = string_value($0)
            if (!string_ok || oauth_storage[name] == "") invalid = 1
            next
        }
        kind == "provider" && suffix == "oauth" && /^[ \t]*key[ \t]*=/ {
            if (oauth_key_seen[name]++) invalid = 1
            oauth_key[name] = string_value($0)
            if (!string_ok || oauth_key[name] == "") invalid = 1
            next
        }
        END {
            if (invalid || default_model == "") exit 1
            provider = model_provider[default_model]
            if (provider == "" || model_id[default_model] == "" || model_context[default_model] == "") exit 1
            type = provider_type[provider]
            if (type != "kimi" && type != "anthropic" && type != "openai" &&
                type != "openai_responses" && type != "google-genai" && type != "vertexai") exit 1
            if (direct_key[provider]) { print "config:api-key"; exit 0 }
            if ((type == "kimi" && env_key[provider, "KIMI_API_KEY"]) ||
                (type == "anthropic" && env_key[provider, "ANTHROPIC_API_KEY"]) ||
                ((type == "openai" || type == "openai_responses") && env_key[provider, "OPENAI_API_KEY"]) ||
                (type == "google-genai" && env_key[provider, "GOOGLE_API_KEY"]) ||
                (type == "vertexai" && (env_key[provider, "GOOGLE_API_KEY"] || env_key[provider, "VERTEXAI_API_KEY"]))) {
                print "config:env"
                exit 0
            }
            if (oauth_storage[provider] == "file" && oauth_key[provider] != "") {
                print "oauth-file:" oauth_key[provider]
                exit 0
            }
            if (oauth_storage[provider] == "keyring" && oauth_key[provider] != "") {
                print "oauth-keyring:" oauth_key[provider]
                exit 0
            }
            exit 1
        }
    ' "$config"
}

_kimi_oauth_file_exists(){
    local key="$1" storage_name
    case "$key" in
        kimi-code|oauth/kimi-code) storage_name="kimi-code" ;;
        oauth/*) storage_name="${key#oauth/}" ;;
        *) storage_name="$key" ;;
    esac
    [[ -n "$storage_name" && "$storage_name" != */* && "$storage_name" != .* ]] || return 1
    [[ -s "$(kimi_data_root)/credentials/${storage_name}.json" ]]
}

kimi_configured_credential_method(){
    local record
    record="$(_kimi_config_credential_record 2>/dev/null)" || return 1
    case "$record" in
        config:api-key|config:env) printf '%s\n' "$record" ;;
        oauth-file:*)
            _kimi_oauth_file_exists "${record#oauth-file:}" || return 1
            printf '%s\n' "kimi-session"
            ;;
        oauth-keyring:*)
            # Current Kimi Code migrates legacy keyring tokens to the same
            # file-backed store. A config reference alone is not proof of auth.
            _kimi_oauth_file_exists "${record#oauth-keyring:}" || return 1
            printf '%s\n' "kimi-session"
            ;;
        *) return 1 ;;
    esac
}

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
# This helper checks only the top-level pointer. `kimi_is_available` combines it
# with `_kimi_config_credential_record`, which verifies the selected model's
# provider mapping and configured credential source without exposing values.
#
# OCTOPUS_KIMI_MODEL deliberately does not count: kimi resolves -m against this
# same config, so a pin with no matching alias fails just as hard.
kimi_has_model(){
    local config
    config="$(kimi_config_file)"
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
    kimi_has_model || return 1
    kimi_configured_credential_method >/dev/null
}

kimi_auth_method(){
    kimi_configured_credential_method 2>/dev/null || printf '%s\n' "none"
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
    run_with_timeout --portable-supervisor "$timeout" "${cmd[@]}" >"$response_file" 2>"$error_file" && exit_code=0 || exit_code=$?
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
