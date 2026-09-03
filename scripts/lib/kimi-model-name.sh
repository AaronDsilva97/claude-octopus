#!/usr/bin/env bash
# Small shared contract for Kimi aliases. Keep this file dependency-free so the
# standalone kimi-exec.sh shim can validate input without loading Octopus.

[[ -n "${_OCTOPUS_KIMI_MODEL_NAME_LOADED:-}" ]] && return 0
_OCTOPUS_KIMI_MODEL_NAME_LOADED=true

octopus_kimi_model_name_is_safe() {
    local model="${1-}"

    [[ -n "$model" && -n "${model//[[:space:]]/}" ]] || return 1
    [[ "$model" != *$'\n'* && "$model" != *$'\r'* ]] || return 1
    case "$model" in
        *\\*|*"*"*|*";"*|*"|"*|*"&"*|*'$'*|*'`'*|*"'"*|*'"'*|*"("*|*")"*|*"<"*|*">"*|*"!"*|*"?"*|*"["*|*"]"*|*"{"*|*"}"*)
            return 1
            ;;
    esac
    [[ "$model" != /* ]]
}

octopus_kimi_model_from_hex() {
    local encoded="${1-}" decoded="" byte pair
    local index=0

    [[ "$encoded" =~ ^([0-9A-Fa-f][0-9A-Fa-f])+$ ]] || return 1
    while [[ "$index" -lt "${#encoded}" ]]; do
        pair="${encoded:index:2}"
        [[ "$pair" != 00 ]] || return 1
        printf -v byte '%b' "\\x${pair}" || return 1
        decoded="${decoded}${byte}"
        index=$((index + 2))
    done
    octopus_kimi_model_name_is_safe "$decoded" || return 1
    # Encoded transport always means an explicit alias. Treating this value as
    # the no-flag fallback would silently dispatch a different model.
    [[ "$decoded" != default ]] || return 1
    printf '%s' "$decoded"
}
