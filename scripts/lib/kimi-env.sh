#!/usr/bin/env bash
# Shared Kimi environment allowlist for dispatch and readiness checks.

[[ -n "${_OCTOPUS_KIMI_ENV_LOADED:-}" ]] && return 0
_OCTOPUS_KIMI_ENV_LOADED=true

octopus_build_kimi_provider_env() {
    KIMI_PROVIDER_ENV_ARRAY=()
    if [[ "${OCTOPUS_ALLOW_FULL_KIMI_ENV:-false}" == "true" ]]; then
        return 0
    fi

    KIMI_PROVIDER_ENV_ARRAY=(
        env -i
        "PATH=${PATH:-/usr/bin:/bin}"
        "HOME=${HOME:-}"
        "TERM=${TERM:-dumb}"
        "TMPDIR=${TMPDIR:-/tmp}"
    )
    if [[ -n "${KIMI_CODE_HOME:-}" ]]; then
        KIMI_PROVIDER_ENV_ARRAY+=("KIMI_CODE_HOME=${KIMI_CODE_HOME}")
    fi
    if [[ -n "${OCTOPUS_KIMI_MODEL:-}" ]]; then
        KIMI_PROVIDER_ENV_ARRAY+=("OCTOPUS_KIMI_MODEL=${OCTOPUS_KIMI_MODEL}")
    fi

    local kimi_model_var
    for kimi_model_var in \
        KIMI_MODEL_NAME \
        KIMI_MODEL_API_KEY \
        KIMI_MODEL_PROVIDER_TYPE \
        KIMI_MODEL_BASE_URL \
        KIMI_MODEL_MAX_CONTEXT_SIZE \
        KIMI_MODEL_CAPABILITIES \
        KIMI_MODEL_DISPLAY_NAME \
        KIMI_MODEL_MAX_OUTPUT_SIZE \
        KIMI_MODEL_REASONING_KEY \
        KIMI_MODEL_THINKING_EFFORT \
        KIMI_MODEL_ADAPTIVE_THINKING \
        KIMI_MODEL_MAX_COMPLETION_TOKENS \
        KIMI_MODEL_MAX_TOKENS \
        KIMI_MODEL_TEMPERATURE \
        KIMI_MODEL_TOP_P \
        KIMI_MODEL_THINKING_KEEP; do
        if [[ -n "${!kimi_model_var:-}" ]]; then
            KIMI_PROVIDER_ENV_ARRAY+=("${kimi_model_var}=${!kimi_model_var}")
        fi
    done
}
