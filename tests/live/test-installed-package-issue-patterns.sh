#!/usr/bin/env bash
# Public, host-agnostic installed-package UAT derived from recurring issue
# families. This suite makes two bounded provider calls and uses only a
# disposable workspace. Run it only where Claude and Codex usage is authorized.

set -uo pipefail

PASS=0
FAIL=0
SKIP=0
CURRENT_CASE=""

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$CURRENT_CASE"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s: %s\n' "$CURRENT_CASE" "$1" >&2; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s: %s\n' "$CURRENT_CASE" "$1"; }
run_case() {
    CURRENT_CASE="$1"
    shift
    if "$@"; then pass; else fail "contract was not satisfied"; fi
}

stable_root="${OCTOPUS_UAT_STABLE_ROOT:-$HOME/.claude-octopus/plugin}"
plugin_root="${OCTOPUS_UAT_PLUGIN_ROOT:-}"
if [[ -z "$plugin_root" && -d "$stable_root" ]]; then
    plugin_root="$(cd "$stable_root" 2>/dev/null && pwd -P)"
fi
if [[ -z "$plugin_root" || ! -f "$plugin_root/.claude-plugin/plugin.json" ]]; then
    printf 'ERROR: set OCTOPUS_UAT_PLUGIN_ROOT to an installed Octopus package root\n' >&2
    exit 2
fi
plugin_root="$(cd "$plugin_root" && pwd -P)"

UAT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/octopus-installed-uat.XXXXXX")" || exit 2
cleanup() {
    case "$UAT_TMP" in
        "${TMPDIR:-/tmp}"/octopus-installed-uat.*) rm -rf "$UAT_TMP" ;;
    esac
}
trap cleanup EXIT INT TERM
mkdir -p "$UAT_TMP/project with spaces" "$UAT_TMP/plugin-data" "$UAT_TMP/results"

# Run the repository's canonical provider admission check once, before any
# orchestrate.sh invocation. Claude Code itself is intentionally absent from
# this protocol because it is the host runtime; its direct plugin-load check
# below uses `claude auth status` instead.
PROVIDER_STATUS="$UAT_TMP/provider-status.txt"
if ! env \
    "CLAUDE_PLUGIN_ROOT=$plugin_root" \
    "CLAUDE_PLUGIN_DATA=$UAT_TMP/plugin-data" \
    bash "$plugin_root/scripts/helpers/check-providers.sh" > "$PROVIDER_STATUS"; then
    printf 'ERROR: provider availability check failed\n' >&2
    exit 2
fi

provider_available() {
    grep -Fxq "$1:available" "$PROVIDER_STATUS"
}

bounded() {
    local seconds="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$seconds" "$@"
    else
        printf 'A timeout command is required for live UAT\n' >&2
        return 127
    fi
}

version_parity() {
    local expected value
    expected="$(jq -r '.version // empty' "$plugin_root/.claude-plugin/plugin.json")"
    [[ -n "$expected" ]] || return 1
    for value in \
        "$(jq -r '.version // empty' "$plugin_root/package.json")" \
        "$(jq -r '.version // empty' "$plugin_root/.claude-plugin/plugin-manifest.json")" \
        "$(jq -r '.metadata.version // empty' "$plugin_root/.claude-plugin/marketplace.json")" \
        "$(jq -r '.plugins[] | select(.name == "octo") | .version' "$plugin_root/.claude-plugin/marketplace.json")"; do
        [[ "$value" == "$expected" ]] || return 1
    done
}

manifest_paths() {
    local rel
    while IFS= read -r rel; do
        [[ -f "$plugin_root/${rel#./}" ]] || return 1
    done < <(jq -r '.commands[]' "$plugin_root/.claude-plugin/plugin.json")
    while IFS= read -r rel; do
        [[ -f "$plugin_root/${rel#./}/SKILL.md" ]] || return 1
    done < <(jq -r '.skills[]' "$plugin_root/.claude-plugin/plugin.json")
    [[ ! -e "$plugin_root/commands/doctor.md" ]] &&
        [[ -f "$plugin_root/skills/skill-doctor/SKILL.md" ]]
}

stable_link() {
    [[ -d "$stable_root" ]] || return 1
    local before after
    before="$(cd "$stable_root" && pwd -P)" || return 1
    [[ "$before" == "$plugin_root" ]] || return 1
    (
        cd "$UAT_TMP/project with spaces" || exit 1
        env \
            "CLAUDE_PLUGIN_ROOT=$stable_root" \
            "CLAUDE_PLUGIN_DATA=$UAT_TMP/plugin-data" \
            "OCTOPUS_SKIP_PROVIDER_PROBES=true" \
            bash "$stable_root/scripts/orchestrate.sh" --help >/dev/null
    ) || return 1
    after="$(cd "$stable_root" && pwd -P)" || return 1
    [[ "$after" == "$before" ]]
}

independent_cwd() {
    (
        cd "$UAT_TMP/project with spaces" || exit 1
        [[ ! -d .git ]] || exit 1
        env \
            "CLAUDE_PLUGIN_ROOT=$plugin_root" \
            "CLAUDE_PLUGIN_DATA=$UAT_TMP/plugin-data" \
            "OCTOPUS_SKIP_PROVIDER_PROBES=true" \
            bash "$plugin_root/scripts/orchestrate.sh" --help >/dev/null
    )
}

doctor_json() {
    local output="$UAT_TMP/doctor.json"
    (
        cd "$UAT_TMP/project with spaces" || exit 1
        env \
            "CLAUDE_PLUGIN_ROOT=$plugin_root" \
            "CLAUDE_PLUGIN_DATA=$UAT_TMP/plugin-data" \
            "OCTOPUS_SKIP_PROVIDER_PROBES=true" \
            bash "$plugin_root/scripts/orchestrate.sh" doctor skills --json
    ) > "$output" 2> "$UAT_TMP/doctor.err" || true
    jq -e '.schema_version == "10.0" and (.summary.total > 0) and (.results | type == "array")' "$output" >/dev/null
}

late_flag_rejection() {
    local output="$UAT_TMP/late-flag.log" rc=0
    (
        cd "$UAT_TMP/project with spaces" || exit 1
        env \
            "CLAUDE_PLUGIN_ROOT=$plugin_root" \
            "CLAUDE_PLUGIN_DATA=$UAT_TMP/plugin-data" \
            "OCTOPUS_SKIP_PROVIDER_PROBES=true" \
            bash "$plugin_root/scripts/orchestrate.sh" define --timeout 9 OCTOPUS_UAT_PROMPT --dry-run
    ) > "$output" 2>&1 || rc=$?
    [[ "$rc" -ne 0 ]] && grep -Fq "looks like a flag but was read as the prompt" "$output"
}

claude_plugin_load() {
    command -v claude >/dev/null 2>&1 || { skip "Claude Code unavailable"; return 2; }
    claude auth status >/dev/null 2>&1 || { skip "Claude Code unauthenticated"; return 2; }
    local output="$UAT_TMP/claude.jsonl"
    (
        cd "$UAT_TMP/project with spaces" || exit 1
        bounded 120 env \
            "CLAUDE_PLUGIN_DATA=$UAT_TMP/plugin-data" \
            claude --plugin-dir "$plugin_root" --print --output-format stream-json \
            --include-hook-events --verbose --dangerously-skip-permissions \
            "Reply exactly: OCTOPUS_CLAUDE_UAT_OK" </dev/null
    ) > "$output" 2>&1 || return 1
    jq --slurp -e \
        '[.[] | select(.type == "system" and .subtype == "init") | .plugin_errors[]?] | length == 0' \
        "$output" >/dev/null &&
        grep -Fq 'OCTOPUS_CLAUDE_UAT_OK' "$output"
}

codex_dispatch() {
    provider_available codex || { skip "Codex unavailable or unauthenticated"; return 2; }
    local task_id="installed-uat-$$" output="$UAT_TMP/codex.log"
    (
        cd "$UAT_TMP/project with spaces" || exit 1
        bounded 150 env \
            "CLAUDE_PLUGIN_ROOT=$plugin_root" \
            "CLAUDE_PLUGIN_DATA=$UAT_TMP/plugin-data" \
            "OCTOPUS_SKIP_PROVIDER_PROBES=true" \
            "OCTOPUS_AGENT_TIMEOUT=120" \
            bash "$plugin_root/scripts/orchestrate.sh" probe-single codex \
            "Reply exactly: OCTOPUS_CODEX_UAT_OK" "$task_id" \
            "Installed-package provider contract" --output-dir "$UAT_TMP/results" </dev/null
    ) > "$output" 2>&1 || return 1
    local artifact="$UAT_TMP/results/codex-${task_id}.md"
    [[ -s "$artifact" ]] && grep -Fq 'OCTOPUS_CODEX_UAT_OK' "$artifact" &&
        grep -Eq '^## Status: SUCCESS' "$artifact"
}

bounded_runtime() { command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; }
artifact_cleanup() {
    ! find "$UAT_TMP/results" -type f \( -name '.tmp-*' -o -name '.raw-*' \) -print -quit | grep -q .
}
codex_artifact_contract() {
    find "$UAT_TMP/results" -type f -name 'codex-installed-uat-*.md' -size +100c -print -quit | grep -q .
}

run_case "version-parity" version_parity
run_case "manifest-paths" manifest_paths
run_case "stable-link" stable_link
run_case "independent-cwd" independent_cwd
run_case "doctor-json" doctor_json
run_case "late-flag-rejection" late_flag_rejection
run_case "bounded-runtime" bounded_runtime

# Provider calls are deliberately last: structural failures remain visible even
# when authentication or quota prevents live dispatch.
CURRENT_CASE="claude-plugin-load"
claude_plugin_load; rc=$?
[[ "$rc" -eq 0 ]] && pass || { [[ "$rc" -eq 2 ]] || fail "plugin load or response contract failed"; }

CURRENT_CASE="codex-dispatch"
codex_dispatch; rc=$?
[[ "$rc" -eq 0 ]] && pass || { [[ "$rc" -eq 2 ]] || fail "dispatch or result contract failed"; }

CURRENT_CASE="codex-artifact-contract"
if [[ "$rc" -eq 2 ]]; then
    skip "Codex dispatch was skipped"
elif codex_artifact_contract; then
    pass
else
    fail "durable Codex artifact was missing or empty"
fi
run_case "artifact-cleanup" artifact_cleanup

printf '\nInstalled-package UAT: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
