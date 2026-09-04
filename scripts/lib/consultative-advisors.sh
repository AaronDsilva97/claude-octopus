#!/usr/bin/env bash
# Shared admission and launch contract for brainstorm and debate advisors.
# Sourced library: do not change the caller's shell options.

_octo_consultative_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
_octo_consultative_allowlist="${_octo_consultative_lib_dir}/provider-allowlist.sh"
if [[ ! -r "$_octo_consultative_allowlist" ]] ||
   ! source "$_octo_consultative_allowlist"; then
    printf 'ERROR: consultative advisor allowlist is unavailable\n' >&2
    return 1 2>/dev/null || exit 1
fi

octo_consultative_provider_is_launchable() {
    local provider="${1%%:*}"
    case "$provider" in
        codex|commandcode|grok|agy|gemini|antigravity|copilot|qwen|\
        cursor-agent|opencode|ollama|vibe|openrouter|openai-compatible|\
        atlascloud-agent|perplexity)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

octo_consultative_host_allowed() {
    octo_provider_allowed claude-sonnet
}

octo_consultative_required_external_count() {
    if octo_consultative_host_allowed; then
        printf '1\n'
    else
        printf '2\n'
    fi
}

octo_consultative_provider_count_is_sufficient() {
    local external_count="$1" host_count="$2"
    case "$external_count" in ""|*[!0-9]*) return 1 ;; esac
    case "$host_count" in ""|*[!0-9]*) return 1 ;; esac
    [[ $((external_count + host_count)) -ge 2 ]]
}

# Launch every selected external advisor, wait for each exact PID, and print the
# number that exited successfully with a non-empty response. Return nonzero when
# fewer than required_successes produce usable output.
octo_launch_advisors() {
    local orchestrator="$1" advisors_csv="$2" output_dir="$3"
    local filename_prefix="$4" prompt_template="$5" required_successes="$6"
    local advisor safe_advisor prompt response_file pid index successful_count=0
    local advisor_list=() advisor_pids=() advisor_files=()

    [[ -x "$orchestrator" ]] || {
        printf 'ERROR: advisor orchestrator is not executable: %s\n' "$orchestrator" >&2
        return 1
    }
    [[ -d "$output_dir" && -w "$output_dir" ]] || {
        printf 'ERROR: advisor output directory is not writable: %s\n' "$output_dir" >&2
        return 1
    }
    case "$required_successes" in
        ""|*[!0-9]*|0)
            printf 'ERROR: required advisor count must be a positive integer\n' >&2
            return 1
            ;;
    esac

    IFS=',' read -r -a advisor_list <<< "$advisors_csv"
    for advisor in "${advisor_list[@]}"; do
        [[ -n "$advisor" ]] || continue
        octo_consultative_provider_is_launchable "$advisor" || continue
        octo_provider_allowed "$advisor" || continue
        safe_advisor="$(printf '%s' "$advisor" | tr -c '[:alnum:]_-' '_')"
        response_file="${output_dir}/${filename_prefix}${safe_advisor}.md"
        prompt="${prompt_template//\{\{advisor\}\}/$advisor}"
        "$orchestrator" spawn "$advisor" "$prompt" > "$response_file" &
        index=${#advisor_pids[@]}
        advisor_pids[$index]=$!
        advisor_files[$index]="$response_file"
    done

    if [[ ${#advisor_pids[@]} -eq 0 ]]; then
        printf 'ERROR: no launchable external advisors were selected\n' >&2
        return 1
    fi

    index=0
    while [[ $index -lt ${#advisor_pids[@]} ]]; do
        pid="${advisor_pids[$index]}"
        response_file="${advisor_files[$index]}"
        if wait "$pid" && [[ -s "$response_file" ]]; then
            successful_count=$((successful_count + 1))
        fi
        index=$((index + 1))
    done

    if [[ "$successful_count" -lt "$required_successes" ]]; then
        printf 'ERROR: only %s of %s required external advisors succeeded\n' \
            "$successful_count" "$required_successes" >&2
        return 1
    fi
    printf '%s\n' "$successful_count"
}
