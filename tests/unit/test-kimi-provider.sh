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
#   6. the Kimi request timeout still works without GNU/BSD timeout.
#   7. stderr-only authentication failures receive actionable guidance without
#      contaminating successful response output.
#   8. kimi_is_available requires the binary AND auth AND a model kimi itself
#      declares — an octo-side pin alone is not proof of readiness.
#   9. standard dispatch validation and configured routing accept both Kimi
#      agent types and give them a stable display label.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
PLUGIN_DIR="$PROJECT_ROOT"
source "$PROJECT_ROOT/scripts/lib/model-resolver.sh" 2>/dev/null || true
source "$PROJECT_ROOT/scripts/lib/dispatch.sh" 2>/dev/null || true
source "$PROJECT_ROOT/scripts/lib/routing.sh" 2>/dev/null || true
source "$PROJECT_ROOT/scripts/lib/parallel.sh" 2>/dev/null || true

test_suite "Moonshot Kimi Code CLI Provider"

# Stub log() — kimi.sh/model-resolver.sh call it outside orchestrate.sh.
log() { :; }

# Restore MOONSHOT_API_KEY exactly as found — including "was not set at all",
# which a plain -n check would silently turn into "keep the fake test key".
_kimi_restore_key() {
    if [[ -n "$1" ]]; then export MOONSHOT_API_KEY="$2"; else unset MOONSHOT_API_KEY; fi
}

_kimi_mock_bin() {
    local dir="$1" body="$2"
    mkdir -p "$dir"
    printf '%s\n' '#!/usr/bin/env bash' "$body" > "$dir/kimi"
    chmod +x "$dir/kimi"
}

_kimi_fake_system_timeout_bins() {
    local dir="$1" timeout_name
    mkdir -p "$dir"
    for timeout_name in gtimeout timeout; do
        cat > "$dir/$timeout_name" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" >> "${FAKE_TIMEOUT_USED:?}"
shift 3
"$@"
MOCK
        chmod +x "$dir/$timeout_name"
    done
}

# A mock that enforces the real CLI's argument contract, so a permissive mock
# cannot green-light an invocation kimi would reject. Mirrors kimi 0.39.1:
#   -p/--prompt is single-turn and cannot be combined with --auto
#     ("error: Cannot combine --prompt with --auto.")
#   unknown flags are rejected ("error: unknown option '<flag>'")
_kimi_strict_mock_bin() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/kimi" <<'MOCK'
#!/usr/bin/env bash
have_prompt=0; have_auto=0
args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
        -p|--prompt)        have_prompt=1; i=$((i+2)); continue ;;
        --auto)             have_auto=1 ;;
        --output-format)    i=$((i+2)); continue ;;
        -m|--model)         i=$((i+2)); continue ;;
        -y|--yolo|--plan)   ;;
        *) echo "error: unknown option '${args[$i]}'" >&2; exit 1 ;;
    esac
    i=$((i+1))
done
if [[ $have_prompt -eq 1 && $have_auto -eq 1 ]]; then
    echo "error: Cannot combine --prompt with --auto." >&2; exit 1
fi
[[ $have_prompt -eq 1 ]] || { echo "error: no prompt" >&2; exit 1; }
printf 'MOCK_KIMI_OK\n'
MOCK
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

test_kimi_stderr_auth_classification() {
    test_case "kimi_execute classifies stderr-only auth failures"
    local tmp_bin old_path output rc=0
    tmp_bin="$TEST_TMP_DIR/kimi-bin-auth-stderr"
    _kimi_mock_bin "$tmp_bin" 'printf "Login required: token expired\n" >&2; exit 1'
    old_path="$PATH"; PATH="$tmp_bin:$PATH"
    source "$PROJECT_ROOT/scripts/lib/kimi.sh" 2>/dev/null || true
    log() { printf '[%s] %s\n' "$1" "${*:2}" >&2; }

    output="$(kimi_execute kimi "probe" 2>&1)" || rc=$?
    log() { :; }
    PATH="$old_path"

    if [[ "$rc" -ne 0 && "$output" == *"kimi: auth failure"* && "$output" != *"kimi: exit 1"* ]]; then
        test_pass
    else
        test_fail "expected stderr-only auth guidance, got rc=$rc output='$output'"
    fi
}

test_kimi_success_stderr_is_not_response() {
    test_case "kimi_execute discards successful stderr instead of exposing it as response or diagnostics"
    local tmp_bin old_path output_file stderr_file rc=0 response stdout_response call_output
    tmp_bin="$TEST_TMP_DIR/kimi-bin-success-stderr"
    output_file="$TEST_TMP_DIR/kimi-success.out"
    stderr_file="$TEST_TMP_DIR/kimi-success.err"
    _kimi_mock_bin "$tmp_bin" 'printf "provider diagnostic\n" >&2; printf "answer\n"; exit 0'
    old_path="$PATH"; PATH="$tmp_bin:$PATH"
    source "$PROJECT_ROOT/scripts/lib/kimi.sh" 2>/dev/null || true

    stdout_response="$(kimi_execute kimi "probe" 2>"$stderr_file")" || rc=$?
    call_output="$(kimi_execute kimi "probe" "$output_file" 2>"$stderr_file")" || rc=$?
    PATH="$old_path"
    response="$(< "$output_file")"

    if [[ "$rc" -eq 0 && "$stdout_response" == "answer" && -z "$call_output" &&
          "$response" == "answer" && "$response" != *"provider diagnostic"* &&
          ! -s "$stderr_file" ]]; then
        test_pass
    else
        test_fail "expected successful stderr to be discarded in both output modes, got rc=$rc stdout='$stdout_response' file-call-stdout='$call_output' response='$response' caller-stderr-bytes=$(wc -c < "$stderr_file" | tr -d ' ')"
    fi
}

test_kimi_interruption_cleans_private_captures() {
    test_case "kimi_execute removes private captures before preserving default TERM semantics"
    local case_dir="$TEST_TMP_DIR/kimi-interrupt-default"
    local tmp_bin="$case_dir/bin" harness="$case_dir/harness.sh"
    local started_file="$case_dir/kimi.pid" harness_pid="" kimi_pid="" rc=0
    local leaks="" kimi_alive=false attempt
    mkdir -p "$case_dir"
    _kimi_mock_bin "$tmp_bin" 'printf "%s\n" "$$" > "${KIMI_STARTED:?}"; trap "" TERM; exec /bin/sleep 30'
    cat > "$harness" <<'EOF'
#!/bin/bash
set -u
source "$PROJECT_ROOT/scripts/lib/kimi.sh"
log() { :; }
command() {
    if [[ "${1:-}" == "-v" && ( "${2:-}" == "gtimeout" || "${2:-}" == "timeout" ) ]]; then
        return 1
    fi
    builtin command "$@"
}
OCTOPUS_KIMI_TIMEOUT=30 kimi_execute kimi "probe" >/dev/null 2>&1
EOF
    chmod +x "$harness"

    TMPDIR="$case_dir" PATH="$tmp_bin:$PATH" PROJECT_ROOT="$PROJECT_ROOT" \
        KIMI_STARTED="$started_file" /bin/bash "$harness" &
    harness_pid=$!
    for ((attempt=0; attempt<100; attempt++)); do
        [[ -s "$started_file" ]] && break
        sleep 0.05
    done
    if [[ -s "$started_file" ]]; then
        kimi_pid="$(< "$started_file")"
        kill -TERM "$harness_pid"
    else
        kill -KILL "$harness_pid" 2>/dev/null || true
    fi
    set +e
    wait "$harness_pid"
    rc=$?
    set -e
    sleep 0.2

    if [[ -n "$kimi_pid" ]] && kill -0 "$kimi_pid" 2>/dev/null; then
        local process_stat
        process_stat="$(/bin/ps -o stat= -p "$kimi_pid" 2>/dev/null | tr -d '[:space:]')"
        [[ -n "$process_stat" && "$process_stat" != Z* ]] && kimi_alive=true
    fi
    leaks="$(find "$case_dir" -maxdepth 1 \( -name 'octo-kimi-response.*' -o -name 'octo-kimi-error.*' -o -name 'octo-timeout.*' \) -print)"
    if [[ "$kimi_alive" == true ]]; then kill -KILL "$kimi_pid" 2>/dev/null || true; fi

    if [[ "$rc" -eq 143 && -n "$kimi_pid" && "$kimi_alive" == false && -z "$leaks" ]]; then
        test_pass
    else
        test_fail "expected TERM rc=143, dead Kimi, and no private temp files; got rc=$rc pid=${kimi_pid:-missing}/$kimi_alive leaks='${leaks:-none}'"
    fi
}

test_kimi_interruption_restores_caller_trap() {
    test_case "kimi_execute restores a returning caller TERM trap and returns 143"
    local case_dir="$TEST_TMP_DIR/kimi-interrupt-trap"
    local tmp_bin="$case_dir/bin" harness="$case_dir/harness.sh"
    local started_file="$case_dir/kimi.pid" trap_hits="$case_dir/trap-hits"
    local before="$case_dir/trap-before" after="$case_dir/trap-after"
    local harness_pid="" kimi_pid="" rc=0 hit_count=0 leaks="" kimi_alive=false attempt
    mkdir -p "$case_dir"
    _kimi_mock_bin "$tmp_bin" 'printf "%s\n" "$$" > "${KIMI_STARTED:?}"; exec /bin/sleep 30'
    cat > "$harness" <<'EOF'
#!/bin/bash
set -u
source "$PROJECT_ROOT/scripts/lib/kimi.sh"
log() { :; }
command() {
    if [[ "${1:-}" == "-v" && ( "${2:-}" == "gtimeout" || "${2:-}" == "timeout" ) ]]; then
        return 1
    fi
    builtin command "$@"
}
trap 'printf "TERM\n" >> "$TRAP_HITS"' TERM
trap -p TERM > "$TRAP_BEFORE"
set +e
OCTOPUS_KIMI_TIMEOUT=30 kimi_execute kimi "probe" >/dev/null 2>&1
rc=$?
set -e
trap -p TERM > "$TRAP_AFTER"
kill -TERM "$$"
exit "$rc"
EOF
    chmod +x "$harness"

    TMPDIR="$case_dir" PATH="$tmp_bin:$PATH" PROJECT_ROOT="$PROJECT_ROOT" KIMI_STARTED="$started_file" \
        TRAP_HITS="$trap_hits" TRAP_BEFORE="$before" TRAP_AFTER="$after" /bin/bash "$harness" &
    harness_pid=$!
    for ((attempt=0; attempt<100; attempt++)); do
        [[ -s "$started_file" ]] && break
        sleep 0.05
    done
    if [[ -s "$started_file" ]]; then
        kimi_pid="$(< "$started_file")"
        kill -TERM "$harness_pid"
    else
        kill -KILL "$harness_pid" 2>/dev/null || true
    fi
    set +e
    wait "$harness_pid"
    rc=$?
    set -e
    [[ -f "$trap_hits" ]] && hit_count="$(wc -l < "$trap_hits" | tr -d ' ')"
    sleep 0.2
    if [[ -n "$kimi_pid" ]] && kill -0 "$kimi_pid" 2>/dev/null; then
        local process_stat
        process_stat="$(/bin/ps -o stat= -p "$kimi_pid" 2>/dev/null | tr -d '[:space:]')"
        [[ -n "$process_stat" && "$process_stat" != Z* ]] && kimi_alive=true
    fi
    leaks="$(find "$case_dir" -maxdepth 1 \( -name 'octo-kimi-response.*' -o -name 'octo-kimi-error.*' -o -name 'octo-timeout.*' \) -print)"
    if [[ "$kimi_alive" == true ]]; then kill -KILL "$kimi_pid" 2>/dev/null || true; fi

    if [[ "$rc" -eq 143 && "$hit_count" -eq 2 && -s "$before" && -s "$after" ]] &&
       cmp -s "$before" "$after" && [[ "$kimi_alive" == false && -z "$leaks" ]]; then
        test_pass
    else
        test_fail "expected rc=143, restored trap invoked twice, dead Kimi, and no temp files; got rc=$rc hits=$hit_count pid=${kimi_pid:-missing}/$kimi_alive leaks='${leaks:-none}'"
    fi
}

test_kimi_interruption_bypasses_system_timeout() {
    local timeout_name signal_name expected_status case_dir bin_dir harness
    local started_file completed_file used_file harness_rc leaks kimi_pid process_stat
    local kimi_alive

    for timeout_name in gtimeout timeout; do
        for signal_name in INT TERM; do
            expected_status=130
            [[ "$signal_name" == "TERM" ]] && expected_status=143
            test_case "kimi_execute uses the portable supervisor for $signal_name when $timeout_name is available"

            case_dir="$TEST_TMP_DIR/kimi-system-timeout-${timeout_name}-${signal_name}"
            bin_dir="$case_dir/bin"
            harness="$case_dir/harness.sh"
            started_file="$case_dir/kimi.pid"
            completed_file="$case_dir/kimi.completed"
            used_file="$case_dir/system-timeout.used"
            mkdir -p "$case_dir"
            _kimi_mock_bin "$bin_dir" 'printf "%s\n" "$$" > "${KIMI_STARTED:?}"; trap "" TERM; /bin/sleep 2; : > "${KIMI_COMPLETED:?}"; printf "late response\n"'
            _kimi_fake_system_timeout_bins "$bin_dir"
            cat > "$harness" <<'EOF'
#!/bin/bash
set -u
source "$PROJECT_ROOT/scripts/lib/kimi.sh"
log() { :; }
if [[ "$TIMEOUT_NAME" == "timeout" ]]; then
    command() {
        if [[ "${1:-}" == "-v" && "${2:-}" == "gtimeout" ]]; then
            return 1
        fi
        builtin command "$@"
    }
fi
source "$PROJECT_ROOT/scripts/lib/heartbeat.sh"
run_with_timeout 2 /usr/bin/true >/dev/null 2>&1 || exit 90
[[ -s "$FAKE_TIMEOUT_USED" ]] || exit 91
rm -f "$FAKE_TIMEOUT_USED"
(
    sleep 0.2
    kill -"$SIGNAL_NAME" "$$"
) &
OCTOPUS_KIMI_TIMEOUT=30 kimi_execute kimi "probe" >/dev/null 2>&1
EOF
            chmod +x "$harness"

            set +e
            TMPDIR="$case_dir" PATH="$bin_dir:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
                TIMEOUT_NAME="$timeout_name" SIGNAL_NAME="$signal_name" \
                KIMI_STARTED="$started_file" KIMI_COMPLETED="$completed_file" \
                FAKE_TIMEOUT_USED="$used_file" \
                /bin/bash "$harness" >/dev/null 2>&1
            harness_rc=$?
            set -e

            kimi_pid=""
            [[ -s "$started_file" ]] && kimi_pid="$(< "$started_file")"
            kimi_alive=false
            if [[ "$kimi_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$kimi_pid" 2>/dev/null; then
                process_stat="$(/bin/ps -o stat= -p "$kimi_pid" 2>/dev/null | tr -d '[:space:]')"
                [[ -n "$process_stat" && "$process_stat" != Z* ]] && kimi_alive=true
            fi
            leaks="$(find "$case_dir" -maxdepth 1 \( -name 'octo-kimi-response.*' -o -name 'octo-kimi-error.*' \) -print)"
            if [[ "$kimi_alive" == true ]]; then
                kill -KILL "$kimi_pid" 2>/dev/null || true
            fi

            if [[ "$harness_rc" -eq "$expected_status" && -n "$kimi_pid" &&
                  "$kimi_alive" == false && -z "$leaks" && ! -e "$used_file" &&
                  ! -e "$completed_file" ]]; then
                test_pass
            else
                test_fail "expected rc=$expected_status, killed provider, clean captures, and unused $timeout_name; got rc=$harness_rc pid=${kimi_pid:-missing}/$kimi_alive completed=$([[ -e "$completed_file" ]] && echo yes || echo no) leaks='${leaks:-none}' timeout-used=$([[ -e "$used_file" ]] && echo yes || echo no)"
            fi
        done
    done
}

# ── 8. request timeout uses the shared portable watchdog ─────────────────────
test_kimi_portable_timeout() {
    test_case "kimi_execute enforces its timeout without GNU/BSD timeout"
    local tmp_bin started_file old_path rc started_ms elapsed_ms
    tmp_bin="$TEST_TMP_DIR/kimi-bin-timeout"
    started_file="$TEST_TMP_DIR/kimi-timeout-started"
    _kimi_mock_bin "$tmp_bin" 'printf "started\n" > "${KIMI_TIMEOUT_STARTED:?}"; /bin/sleep 4; printf "late response\n"'
    old_path="$PATH"; PATH="$tmp_bin:$PATH"
    export KIMI_TIMEOUT_STARTED="$started_file"

    # Force the shared timeout implementation down its macOS-compatible
    # watchdog path while leaving the rest of PATH available to that watchdog.
    command() {
        if [[ "${1:-}" == "-v" && ( "${2:-}" == "gtimeout" || "${2:-}" == "timeout" ) ]]; then
            return 1
        fi
        builtin command "$@"
    }

    started_ms="$(python3 -c 'import time; print(int(time.monotonic() * 1000))')"
    rc=0
    OCTOPUS_KIMI_TIMEOUT=1 kimi_execute kimi "probe" >/dev/null 2>&1 || rc=$?
    elapsed_ms=$(( $(python3 -c 'import time; print(int(time.monotonic() * 1000))') - started_ms ))

    unset -f command
    unset KIMI_TIMEOUT_STARTED
    PATH="$old_path"
    if [[ -s "$started_file" && "$rc" -ne 0 && "$elapsed_ms" -lt 3000 ]]; then
        test_pass
    else
        test_fail "expected a started, bounded non-zero result, got rc=$rc after ${elapsed_ms}ms"
    fi
}

# ── 9. an octo-side model pin is not proof of readiness ──────────────────────
test_kimi_pin_is_not_readiness() {
    test_case "OCTOPUS_KIMI_MODEL does not substitute for kimi's own default_model"
    local tmp_bin old_path old_home old_key had_key rc_pin_only rc_default
    tmp_bin="$TEST_TMP_DIR/kimi-bin-pin"
    _kimi_mock_bin "$tmp_bin" 'exit 0'
    old_path="$PATH"; old_home="$HOME"; old_key="${MOONSHOT_API_KEY-}"; had_key="${MOONSHOT_API_KEY+set}"
    PATH="$tmp_bin:$PATH"; HOME="$TEST_TMP_DIR/kimi-pin-home"; mkdir -p "$HOME/.kimi-code"
    source "$PROJECT_ROOT/scripts/lib/kimi.sh" 2>/dev/null || true
    MOONSHOT_API_KEY="moonshot-test-key"

    # A model alias declared but no default_model: kimi resolves -m against its
    # own config, so a pin here is not evidence a dispatch can succeed.
    printf '[models."kimi-k2.5"]\nprovider = "kimi"\n' > "$HOME/.kimi-code/config.toml"
    rc_pin_only=0; OCTOPUS_KIMI_MODEL="kimi-k2.5" kimi_is_available >/dev/null 2>&1 || rc_pin_only=$?

    printf 'default_model = "kimi-k2.5"\n' > "$HOME/.kimi-code/config.toml"
    rc_default=0; kimi_is_available >/dev/null 2>&1 || rc_default=$?

    PATH="$old_path"; HOME="$old_home"; _kimi_restore_key "$had_key" "$old_key"
    if [[ "$rc_pin_only" -ne 0 && "$rc_default" -eq 0 ]]; then
        test_pass
    else
        test_fail "expected pin-only!=0 ($rc_pin_only) and default_model=0 ($rc_default)"
    fi
}

# ── 9b. default_model must have a value, not just a key ──────────────────────
test_kimi_empty_default_model() {
    test_case "default_model with an empty value is not readiness"
    local tmp_bin old_path old_home old_key had_key rc_empty rc_bare rc_set
    tmp_bin="$TEST_TMP_DIR/kimi-bin-empty"
    _kimi_mock_bin "$tmp_bin" 'exit 0'
    old_path="$PATH"; old_home="$HOME"; old_key="${MOONSHOT_API_KEY-}"; had_key="${MOONSHOT_API_KEY+set}"
    PATH="$tmp_bin:$PATH"; HOME="$TEST_TMP_DIR/kimi-empty-model-home"; mkdir -p "$HOME/.kimi-code"
    source "$PROJECT_ROOT/scripts/lib/kimi.sh" 2>/dev/null || true
    MOONSHOT_API_KEY="moonshot-test-key"

    printf 'default_model = ""\n' > "$HOME/.kimi-code/config.toml"
    rc_empty=0; kimi_is_available >/dev/null 2>&1 || rc_empty=$?
    printf 'default_model =\n' > "$HOME/.kimi-code/config.toml"
    rc_bare=0; kimi_is_available >/dev/null 2>&1 || rc_bare=$?
    printf 'default_model = "kimi-k2.5"\n' > "$HOME/.kimi-code/config.toml"
    rc_set=0; kimi_is_available >/dev/null 2>&1 || rc_set=$?

    PATH="$old_path"; HOME="$old_home"; _kimi_restore_key "$had_key" "$old_key"
    if [[ "$rc_empty" -ne 0 && "$rc_bare" -ne 0 && "$rc_set" -eq 0 ]]; then
        test_pass
    else
        test_fail "expected empty!=0 ($rc_empty) bare!=0 ($rc_bare) set=0 ($rc_set)"
    fi
}

# ── 9c. the dispatch command is one the real CLI would accept ────────────────
test_kimi_dispatch_command_is_valid() {
    test_case "dispatch's kimi command survives the real CLI's argument contract"
    local tmp_bin old_path out rc cmd
    tmp_bin="$TEST_TMP_DIR/kimi-bin-strict"
    _kimi_strict_mock_bin "$tmp_bin"
    old_path="$PATH"; PATH="$tmp_bin:$PATH"

    # Take the command dispatch.sh actually builds, strip any env prefix, and
    # run it exactly as spawn.sh would: flags as argv, prompt on stdin.
    PLUGIN_DIR="$PROJECT_ROOT"
    cmd="$(get_agent_command kimi 2>/dev/null)"
    cmd="${cmd#env *MODEL=* }"
    # `|| rc=$?` not `; rc=$?` — the suite runs under `set -e`, which would
    # abort on a failing assignment and make this test unable to fail at all.
    rc=0
    # shellcheck disable=SC2086
    out="$(printf 'probe' | bash $cmd 2>&1)" || rc=$?
    PATH="$old_path"

    if [[ "$rc" -eq 0 && "$out" == *MOCK_KIMI_OK* ]]; then
        test_pass
    else
        test_fail "dispatch command rejected by the CLI argument contract: rc=$rc out=$out"
    fi
}

# ── 10. availability requires binary AND auth AND a configured model ──────────
test_kimi_detection() {
    test_case "kimi_is_available requires the kimi binary, auth, and a model"
    local tmp_bin old_path old_home old_key had_key rc_ready rc_nomodel rc_noauth
    tmp_bin="$TEST_TMP_DIR/kimi-bin-det"
    _kimi_mock_bin "$tmp_bin" 'exit 0'
    old_path="$PATH"; old_home="$HOME"; old_key="${MOONSHOT_API_KEY-}"; had_key="${MOONSHOT_API_KEY+set}"
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

    PATH="$old_path"; HOME="$old_home"; _kimi_restore_key "$had_key" "$old_key"
    if [[ "$rc_ready" -eq 0 && "$rc_nomodel" -ne 0 && "$rc_noauth" -ne 0 ]]; then
        test_pass
    else
        test_fail "expected available=0 ($rc_ready), no-model!=0 ($rc_nomodel), no-auth!=0 ($rc_noauth)"
    fi
}

test_kimi_agent_validation() {
    test_case "kimi agent types pass the standard dispatch allowlist"
    local AVAILABLE_AGENTS agent
    AVAILABLE_AGENTS="$(sed -n 's/^AVAILABLE_AGENTS="\([^"]*\)".*/\1/p' "$PROJECT_ROOT/scripts/orchestrate.sh")"

    for agent in kimi kimi-research; do
        if ! validate_agent_type "$agent"; then
            test_fail "expected $agent to pass validate_agent_type"
            return
        fi
    done
    test_pass
}

test_kimi_configured_provider_resolution() {
    test_case "configured kimi providers resolve to labeled agent types"
    local AVAILABLE_AGENTS provider agent label
    AVAILABLE_AGENTS="$(sed -n 's/^AVAILABLE_AGENTS="\([^"]*\)".*/\1/p' "$PROJECT_ROOT/scripts/orchestrate.sh")"

    for provider in kimi kimi-research; do
        agent="$(resolve_provider_to_agent "$provider")" || {
            test_fail "expected configured provider $provider to resolve"
            return
        }
        label="$(agent_display_label "$agent")" || {
            test_fail "expected $agent to have a display label"
            return
        }
        if [[ "$agent" != "$provider" || "$label" != "Kimi" ]]; then
            test_fail "expected $provider|Kimi, got $agent|$label"
            return
        fi
    done
    test_pass
}

test_kimi_dispatch_shim
test_kimi_dispatch_wires_model
test_kimi_env_isolation
test_kimi_config_runtime_model
test_kimi_default_no_model
test_kimi_shim_requires_prompt
test_kimi_exit_propagation
test_kimi_stderr_auth_classification
test_kimi_success_stderr_is_not_response
test_kimi_interruption_cleans_private_captures
test_kimi_interruption_restores_caller_trap
test_kimi_interruption_bypasses_system_timeout
test_kimi_portable_timeout
test_kimi_pin_is_not_readiness
test_kimi_empty_default_model
test_kimi_dispatch_command_is_valid
test_kimi_detection
test_kimi_agent_validation
test_kimi_configured_provider_resolution

test_summary
