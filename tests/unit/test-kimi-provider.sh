#!/bin/bash
# tests/unit/test-kimi-provider.sh
# Contract coverage for the Moonshot Kimi Code CLI provider:
#   1. dispatch routes through the stdin->-p shim (helpers/kimi-exec.sh).
#   2. config/env model selection reaches the shim (get_agent_model +
#      OCTOPUS_KIMI_MODEL env prefix).
#   3. provider-routing isolates kimi by default with a full-env opt-in.
#   4. providers.json kimi model resolves and kimi-exec.sh emits --model;
#      "default" emits no --model.
#   5. kimi_execute propagates a non-zero exit even with stdout.
#   6. kimi_is_available requires the binary AND auth AND a model kimi itself
#      declares — an octo-side pin alone is not proof of readiness.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "Moonshot Kimi Code CLI Provider"

# Stub log() — kimi.sh/model-resolver.sh call it outside orchestrate.sh.
log() { :; }

_kimi_mock_bin() {
    local dir="$1" body="$2"
    mkdir -p "$dir"
    printf '%s\n' '#!/usr/bin/env bash' "$body" > "$dir/kimi"
    chmod +x "$dir/kimi"
}

# ── 1. dispatch routes through the shim ───────────────────────────────────────
test_kimi_dispatch_shim() {
    test_case "dispatch.sh routes kimi through helpers/kimi-exec.sh"
    if grep -q 'scripts/helpers/kimi-exec.sh' "$PROJECT_ROOT/scripts/lib/dispatch.sh" && \
       grep -q 'kimi -p "$prompt"' "$PROJECT_ROOT/scripts/helpers/kimi-exec.sh"; then
        test_pass
    else
        test_fail "kimi dispatch should use scripts/helpers/kimi-exec.sh"
    fi
}

# ── 2. dispatch wires config/env model to the shim ────────────────────────────
test_kimi_dispatch_wires_model() {
    test_case "dispatch kimi arm resolves model and env-prefixes OCTOPUS_KIMI_MODEL"
    local arm
    arm="$(sed -n '/kimi|kimi-research)/,/;;/p' "$PROJECT_ROOT/scripts/lib/dispatch.sh")"
    if [[ "$arm" == *"get_agent_model"* ]] && [[ "$arm" == *"env OCTOPUS_KIMI_MODEL="* ]]; then
        test_pass
    else
        test_fail "kimi arm should call get_agent_model and pass OCTOPUS_KIMI_MODEL to the shim"
    fi
}

# ── 3. provider-routing env isolation parity ──────────────────────────────────
test_kimi_env_isolation() {
    test_case "provider routing isolates kimi by default with full-env opt-in"
    local block
    block="$(sed -n '/kimi\*)/,/;;/p' "$PROJECT_ROOT/scripts/lib/provider-routing.sh")"
    if [[ "$block" == *"OCTOPUS_ALLOW_FULL_KIMI_ENV"* ]] && \
       [[ "$block" == *"PROVIDER_ENV_ARRAY=(env -i"* ]] && \
       [[ "$block" == *"MOONSHOT_API_KEY"* ]] && \
       [[ "$block" == *"PROVIDER_ENV_ARRAY=()"* ]]; then
        test_pass
    else
        test_fail "kimi should isolate by default (env -i + MOONSHOT_API_KEY) and honor OCTOPUS_ALLOW_FULL_KIMI_ENV=true"
    fi
}

# ── 4. config-file model resolves and reaches the shim as --model ─────────────
test_kimi_config_runtime_model() {
    test_case "providers.json kimi model resolves and kimi-exec.sh emits --model"
    local tmp_bin capture config_home old_path old_home resolved
    tmp_bin="$TEST_TMP_DIR/kimi-bin"; capture="$TEST_TMP_DIR/kimi-argv.txt"; config_home="$TEST_TMP_DIR/kimi-home"
    mkdir -p "$config_home/.claude-octopus/config"
    _kimi_mock_bin "$tmp_bin" 'printf "%s\n" "$@" > "${KIMI_ARG_CAPTURE:?}"; exit 0'
    cat > "$config_home/.claude-octopus/config/providers.json" <<'JSON'
{"providers":{"kimi":{"default":"kimi-k2.5"}}}
JSON
    old_path="$PATH"; old_home="$HOME"
    PATH="$tmp_bin:$PATH"; export KIMI_ARG_CAPTURE="$capture"
    source "$PROJECT_ROOT/scripts/lib/model-resolver.sh" 2>/dev/null || true

    HOME="$config_home"
    resolved="$(resolve_octopus_model kimi kimi "" "" 2>/dev/null || true)"
    HOME="$old_home"
    if [[ "$resolved" != "kimi-k2.5" ]]; then
        PATH="$old_path"; unset KIMI_ARG_CAPTURE
        test_fail "config providers.json kimi model should resolve to kimi-k2.5, got: '$resolved'"
        return
    fi

    OCTOPUS_KIMI_MODEL="kimi-k2.5" bash "$PROJECT_ROOT/scripts/helpers/kimi-exec.sh" <<<"probe" >/dev/null 2>&1 || true
    PATH="$old_path"; unset KIMI_ARG_CAPTURE
    if grep -Fxq -- '--model' "$capture" && grep -Fxq -- 'kimi-k2.5' "$capture"; then
        test_pass
    else
        test_fail "kimi-exec.sh should pass the resolved model as --model; argv: $(tr '\n' ' ' < "$capture" 2>/dev/null)"
    fi
}

# ── 5. "default" model => no --model flag ─────────────────────────────────────
test_kimi_default_no_model() {
    test_case "OCTOPUS_KIMI_MODEL=default is not passed to kimi --model"
    local tmp_bin capture old_path
    tmp_bin="$TEST_TMP_DIR/kimi-bin-def"; capture="$TEST_TMP_DIR/kimi-argv-def.txt"
    _kimi_mock_bin "$tmp_bin" 'printf "%s\n" "$@" > "${KIMI_ARG_CAPTURE:?}"; exit 0'
    old_path="$PATH"; PATH="$tmp_bin:$PATH"; export KIMI_ARG_CAPTURE="$capture"
    OCTOPUS_KIMI_MODEL="default" bash "$PROJECT_ROOT/scripts/helpers/kimi-exec.sh" <<<"probe" >/dev/null 2>&1 || true
    PATH="$old_path"; unset KIMI_ARG_CAPTURE
    if grep -q -- '--model' "$capture"; then
        test_fail "default should not be passed to kimi --model; argv: $(tr '\n' ' ' < "$capture" 2>/dev/null)"
    else
        test_pass
    fi
}

# ── 6. empty stdin is rejected before exec ────────────────────────────────────
test_kimi_shim_requires_prompt() {
    test_case "kimi-exec.sh rejects empty stdin with exit 64"
    local rc=0
    printf '' | bash "$PROJECT_ROOT/scripts/helpers/kimi-exec.sh" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq 64 ]]; then test_pass; else test_fail "expected exit 64, got $rc"; fi
}

# ── 7. non-zero exit propagates even with stdout ──────────────────────────────
test_kimi_exit_propagation() {
    test_case "kimi_execute returns non-zero when kimi exits non-zero (even with stdout)"
    local tmp_bin old_path rc
    tmp_bin="$TEST_TMP_DIR/kimi-bin-fail"
    _kimi_mock_bin "$tmp_bin" 'printf "partial answer before crash\n"; exit 3'
    old_path="$PATH"; PATH="$tmp_bin:$PATH"
    source "$PROJECT_ROOT/scripts/lib/kimi.sh" 2>/dev/null || true
    rc=0
    kimi_execute kimi "probe" >/dev/null 2>&1 || rc=$?
    PATH="$old_path"
    if [[ "$rc" -ne 0 ]]; then
        test_pass
    else
        test_fail "kimi_execute masked a non-zero exit (returned 0) despite kimi exiting 3"
    fi
}

# ── 8. an octo-side model pin is not proof of readiness ──────────────────────
test_kimi_pin_needs_native_alias() {
    test_case "OCTOPUS_KIMI_MODEL alone does not make kimi available"
    local tmp_bin old_path old_home old_key rc_unbacked rc_backed
    tmp_bin="$TEST_TMP_DIR/kimi-bin-pin"
    _kimi_mock_bin "$tmp_bin" 'exit 0'
    old_path="$PATH"; old_home="$HOME"; old_key="${MOONSHOT_API_KEY:-}"
    PATH="$tmp_bin:$PATH"; HOME="$TEST_TMP_DIR/kimi-pin-home"; mkdir -p "$HOME/.kimi-code"
    source "$PROJECT_ROOT/scripts/lib/kimi.sh" 2>/dev/null || true
    MOONSHOT_API_KEY="moonshot-test-key"

    # config.toml exists but does not declare the pinned alias: kimi would fail
    # with 'Model "kimi-k2.5" is not configured in config.toml.'
    printf '# empty\n' > "$HOME/.kimi-code/config.toml"
    rc_unbacked=0; OCTOPUS_KIMI_MODEL="kimi-k2.5" kimi_is_available >/dev/null 2>&1 || rc_unbacked=$?

    # same pin, now actually declared by kimi's own config
    printf '[models.kimi-k2.5]\nprovider = "kimi"\n' > "$HOME/.kimi-code/config.toml"
    rc_backed=0; OCTOPUS_KIMI_MODEL="kimi-k2.5" kimi_is_available >/dev/null 2>&1 || rc_backed=$?

    PATH="$old_path"; HOME="$old_home"; [[ -n "$old_key" ]] && export MOONSHOT_API_KEY="$old_key"
    if [[ "$rc_unbacked" -ne 0 && "$rc_backed" -eq 0 ]]; then
        test_pass
    else
        test_fail "expected unbacked pin!=0 ($rc_unbacked) and config-backed pin=0 ($rc_backed)"
    fi
}

# ── 9. availability requires binary AND auth AND a configured model ───────────
test_kimi_detection() {
    test_case "kimi_is_available requires the kimi binary, auth, and a model"
    local tmp_bin old_path old_home old_key rc_ready rc_nomodel rc_noauth
    tmp_bin="$TEST_TMP_DIR/kimi-bin-det"
    _kimi_mock_bin "$tmp_bin" 'exit 0'
    old_path="$PATH"; old_home="$HOME"; old_key="${MOONSHOT_API_KEY:-}"
    PATH="$tmp_bin:$PATH"; HOME="$TEST_TMP_DIR/kimi-empty-home"; mkdir -p "$HOME"
    source "$PROJECT_ROOT/scripts/lib/kimi.sh" 2>/dev/null || true

    MOONSHOT_API_KEY="moonshot-test-key"
    printf 'default_model = "kimi-k2.5"\n' > "$HOME/.kimi-code-config-probe"
    mkdir -p "$HOME/.kimi-code"
    printf 'default_model = "kimi-k2.5"\n' > "$HOME/.kimi-code/config.toml"
    rc_ready=0; kimi_is_available >/dev/null 2>&1 || rc_ready=$?

    rm -f "$HOME/.kimi-code/config.toml"
    rc_nomodel=0; OCTOPUS_KIMI_MODEL="" kimi_is_available >/dev/null 2>&1 || rc_nomodel=$?

    printf 'default_model = "kimi-k2.5"\n' > "$HOME/.kimi-code/config.toml"
    unset MOONSHOT_API_KEY
    rc_noauth=0; kimi_is_available >/dev/null 2>&1 || rc_noauth=$?

    PATH="$old_path"; HOME="$old_home"; [[ -n "$old_key" ]] && export MOONSHOT_API_KEY="$old_key"
    if [[ "$rc_ready" -eq 0 && "$rc_nomodel" -ne 0 && "$rc_noauth" -ne 0 ]]; then
        test_pass
    else
        test_fail "expected available=0 ($rc_ready), no-model!=0 ($rc_nomodel), no-auth!=0 ($rc_noauth)"
    fi
}

test_kimi_dispatch_shim
test_kimi_dispatch_wires_model
test_kimi_env_isolation
test_kimi_config_runtime_model
test_kimi_default_no_model
test_kimi_shim_requires_prompt
test_kimi_exit_propagation
test_kimi_pin_needs_native_alias
test_kimi_detection

test_summary
