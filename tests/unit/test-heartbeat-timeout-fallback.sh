#!/bin/bash
# Regression coverage for the portable run_with_timeout fallback.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
log() { :; }
source "$PROJECT_ROOT/scripts/lib/heartbeat.sh"

test_suite "Heartbeat portable timeout fallback"

_wait_for_nonempty_file() {
    local path="$1" attempt
    for ((attempt=0; attempt<100; attempt++)); do
        [[ -s "$path" ]] && return 0
        sleep 0.05
    done
    return 1
}

_pid_is_live() {
    local pid="$1" process_stat
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    process_stat="$(/bin/ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$process_stat" && "$process_stat" != Z* ]]
}

test_timeout_signals_root_without_ps() {
    test_case "portable timeout signals and reaps its root when ps fails"
    local target="$TEST_TMP_DIR/timeout-root.sh"
    local pid_file="$TEST_TMP_DIR/timeout-root.pid"
    local rc=0 started_ms elapsed_ms target_pid="" alive=false

    cat > "$target" <<'EOF'
#!/bin/bash
printf '%s\n' "$$" > "$1"
exec /bin/sleep 4
EOF
    chmod +x "$target"

    # Force the in-process path and simulate a harness that denies process
    # enumeration. The root PID is still known from `$!` and must be signalled.
    command() {
        if [[ "${1:-}" == "-v" && ( "${2:-}" == "gtimeout" || "${2:-}" == "timeout" ) ]]; then
            return 1
        fi
        builtin command "$@"
    }
    ps() { return 1; }

    started_ms="$(python3 -c 'import time; print(int(time.monotonic() * 1000))')"
    run_with_timeout 1 "$target" "$pid_file" >/dev/null 2>&1 || rc=$?
    elapsed_ms=$(( $(python3 -c 'import time; print(int(time.monotonic() * 1000))') - started_ms ))

    unset -f command ps
    [[ -s "$pid_file" ]] && target_pid="$(< "$pid_file")"
    if [[ -n "$target_pid" ]] && kill -0 "$target_pid" 2>/dev/null; then
        alive=true
        kill -KILL "$target_pid" 2>/dev/null || true
    fi

    if [[ "$rc" -eq 124 && -n "$target_pid" && "$alive" == false && "$elapsed_ms" -lt 3000 ]]; then
        test_pass
    else
        test_fail "expected rc=124, a reaped root, and <3000ms; got rc=$rc pid=${target_pid:-missing} alive=$alive elapsed=${elapsed_ms}ms"
    fi
}

test_pid_reuse_metadata_is_enforced() {
    test_case "timeout signalling retains PID start-time reuse protection"
    local victim_pid expected_started="Wed Sep  2 02:00:00 2026"
    local wrong_snapshot matching_snapshot
    local wrong_preserved=false matching_killed=false

    /bin/sleep 30 &
    victim_pid=$!
    FAKE_PROCESS_STARTED="$expected_started"
    ps() {
        case "$*" in
            *"stat="*) printf '%s\n' "S" ;;
            *"lstart="*) printf '%s\n' "$FAKE_PROCESS_STARTED" ;;
            *) return 1 ;;
        esac
    }
    wrong_snapshot="${victim_pid}"$'\t'"Tue Sep  1 02:00:00 2026"
    matching_snapshot="${victim_pid}"$'\t'"${expected_started}"

    _octo_timeout_signal_snapshot TERM "$wrong_snapshot"
    kill -0 "$victim_pid" 2>/dev/null && wrong_preserved=true
    _octo_timeout_signal_snapshot TERM "$matching_snapshot"
    wait "$victim_pid" 2>/dev/null || true
    kill -0 "$victim_pid" 2>/dev/null || matching_killed=true
    unset -f ps
    unset FAKE_PROCESS_STARTED

    if [[ "$wrong_preserved" == true && "$matching_killed" == true ]]; then
        test_pass
    else
        kill -KILL "$victim_pid" 2>/dev/null || true
        wait "$victim_pid" 2>/dev/null || true
        test_fail "matching start metadata should pass and mismatched metadata should reject the PID"
    fi
}

test_supervisor_isolates_provider_group_without_mutating_caller() {
    test_case "portable supervisor isolates the provider PGID without changing caller job control"
    local caller_pgid provider_pgid monitor_before monitor_after

    caller_pgid="$(/bin/ps -o pgid= -p "$$" | tr -d '[:space:]')"
    monitor_before="$(set -o | awk '$1 == "monitor" { print $2 }')"
    command() {
        if [[ "${1:-}" == "-v" && ( "${2:-}" == "gtimeout" || "${2:-}" == "timeout" ) ]]; then
            return 1
        fi
        builtin command "$@"
    }

    provider_pgid="$(run_with_timeout 2 /bin/sh -c '/bin/ps -o pgid= -p $$ | tr -d "[:space:]"')"
    monitor_after="$(set -o | awk '$1 == "monitor" { print $2 }')"
    unset -f command

    if [[ "$provider_pgid" =~ ^[1-9][0-9]*$ && "$provider_pgid" != "$caller_pgid" &&
          "$monitor_before" == "$monitor_after" ]]; then
        test_pass
    else
        test_fail "expected private provider PGID and unchanged monitor state; got caller=$caller_pgid provider=${provider_pgid:-missing} monitor=$monitor_before->$monitor_after"
    fi
}

test_timeout_kills_term_resistant_descendant_without_ps() {
    test_case "portable timeout kills a TERM-resistant descendant without ps"
    local target="$TEST_TMP_DIR/timeout-tree.sh"
    local root_file="$TEST_TMP_DIR/timeout-tree-root.pid"
    local child_file="$TEST_TMP_DIR/timeout-tree-child.pid"
    local rc=0 started_ms elapsed_ms root_pid="" child_pid=""
    local root_alive=false child_alive=false

    cat > "$target" <<'EOF'
#!/bin/bash
printf '%s\n' "$$" > "$1"
/bin/sh -c 'trap "" TERM; exec /bin/sleep 30' &
printf '%s\n' "$!" > "$2"
wait
EOF
    chmod +x "$target"

    command() {
        if [[ "${1:-}" == "-v" && ( "${2:-}" == "gtimeout" || "${2:-}" == "timeout" ) ]]; then
            return 1
        fi
        builtin command "$@"
    }
    ps() { return 1; }

    started_ms="$(python3 -c 'import time; print(int(time.monotonic() * 1000))')"
    run_with_timeout 1 "$target" "$root_file" "$child_file" >/dev/null 2>&1 || rc=$?
    elapsed_ms=$(( $(python3 -c 'import time; print(int(time.monotonic() * 1000))') - started_ms ))

    unset -f command ps
    [[ -s "$root_file" ]] && root_pid="$(< "$root_file")"
    [[ -s "$child_file" ]] && child_pid="$(< "$child_file")"
    sleep 0.2
    _pid_is_live "$root_pid" && root_alive=true
    _pid_is_live "$child_pid" && child_alive=true

    if [[ "$root_alive" == true ]]; then kill -KILL "$root_pid" 2>/dev/null || true; fi
    if [[ "$child_alive" == true ]]; then kill -KILL "$child_pid" 2>/dev/null || true; fi

    if [[ "$rc" -eq 124 && -n "$root_pid" && -n "$child_pid" &&
          "$root_alive" == false && "$child_alive" == false &&
          "$elapsed_ms" -ge 9000 && "$elapsed_ms" -lt 20000 ]]; then
        test_pass
    else
        test_fail "expected rc=124, a 10s TERM grace, and dead processes within 20s; got rc=$rc root=${root_pid:-missing}/$root_alive child=${child_pid:-missing}/$child_alive elapsed=${elapsed_ms}ms"
    fi
}

test_interruption_cleans_timeout_state_and_preserves_default_term() {
    test_case "portable timeout cleans state before preserving default TERM semantics"
    local case_dir="$TEST_TMP_DIR/timeout-interrupt-default"
    local target="$case_dir/target.sh" harness="$case_dir/harness.sh"
    local root_file="$case_dir/root.pid" harness_pid="" root_pid="" rc=0
    local leaks="" root_alive=false
    mkdir -p "$case_dir"

    cat > "$target" <<'EOF'
#!/bin/bash
printf '%s\n' "$$" > "$1"
exec /bin/sleep 30
EOF
    cat > "$harness" <<'EOF'
#!/bin/bash
set -u
source "$PROJECT_ROOT/scripts/lib/heartbeat.sh"
log() { :; }
command() {
    if [[ "${1:-}" == "-v" && ( "${2:-}" == "gtimeout" || "${2:-}" == "timeout" ) ]]; then
        return 1
    fi
    builtin command "$@"
}
ps() { return 1; }
run_with_timeout 30 "$TARGET" "$ROOT_FILE" >/dev/null 2>&1
EOF
    chmod +x "$target" "$harness"

    TMPDIR="$case_dir" PROJECT_ROOT="$PROJECT_ROOT" TARGET="$target" ROOT_FILE="$root_file" \
        /bin/bash "$harness" &
    harness_pid=$!
    if _wait_for_nonempty_file "$root_file"; then
        root_pid="$(< "$root_file")"
        kill -TERM "$harness_pid"
    else
        kill -KILL "$harness_pid" 2>/dev/null || true
    fi
    set +e
    wait "$harness_pid"
    rc=$?
    set -e
    sleep 0.2

    _pid_is_live "$root_pid" && root_alive=true
    leaks="$(find "$case_dir" -maxdepth 1 -name 'octo-timeout.*' -print)"
    if [[ "$root_alive" == true ]]; then kill -KILL "$root_pid" 2>/dev/null || true; fi

    if [[ "$rc" -eq 143 && -n "$root_pid" && "$root_alive" == false && -z "$leaks" ]]; then
        test_pass
    else
        test_fail "expected TERM rc=143, dead provider, and no marker; got rc=$rc root=${root_pid:-missing}/$root_alive leaks='${leaks:-none}'"
    fi
}

test_interruption_restores_returning_caller_trap() {
    test_case "portable timeout restores a returning caller TERM trap"
    local case_dir="$TEST_TMP_DIR/timeout-interrupt-trap"
    local target="$case_dir/target.sh" harness="$case_dir/harness.sh"
    local root_file="$case_dir/root.pid" trap_hits="$case_dir/trap-hits"
    local before="$case_dir/trap-before" after="$case_dir/trap-after"
    local harness_pid="" root_pid="" rc=0 hit_count=0 root_alive=false
    mkdir -p "$case_dir"

    cat > "$target" <<'EOF'
#!/bin/bash
printf '%s\n' "$$" > "$1"
exec /bin/sleep 30
EOF
    cat > "$harness" <<'EOF'
#!/bin/bash
set -u
source "$PROJECT_ROOT/scripts/lib/heartbeat.sh"
log() { :; }
command() {
    if [[ "${1:-}" == "-v" && ( "${2:-}" == "gtimeout" || "${2:-}" == "timeout" ) ]]; then
        return 1
    fi
    builtin command "$@"
}
ps() { return 1; }
trap 'printf "TERM\n" >> "$TRAP_HITS"' TERM
trap -p TERM > "$TRAP_BEFORE"
set +e
run_with_timeout 30 "$TARGET" "$ROOT_FILE" >/dev/null 2>&1
rc=$?
set -e
trap -p TERM > "$TRAP_AFTER"
kill -TERM "$$"
exit "$rc"
EOF
    chmod +x "$target" "$harness"

    TMPDIR="$case_dir" PROJECT_ROOT="$PROJECT_ROOT" TARGET="$target" ROOT_FILE="$root_file" \
        TRAP_HITS="$trap_hits" TRAP_BEFORE="$before" TRAP_AFTER="$after" /bin/bash "$harness" &
    harness_pid=$!
    if _wait_for_nonempty_file "$root_file"; then
        root_pid="$(< "$root_file")"
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
    _pid_is_live "$root_pid" && root_alive=true
    if [[ "$root_alive" == true ]]; then kill -KILL "$root_pid" 2>/dev/null || true; fi

    if [[ "$rc" -eq 143 && "$hit_count" -eq 2 && -s "$before" &&
          -s "$after" ]] && cmp -s "$before" "$after" && [[ "$root_alive" == false ]]; then
        test_pass
    else
        test_fail "expected rc=143, restored trap invoked twice, and dead provider; got rc=$rc hits=$hit_count root=${root_pid:-missing}/$root_alive"
    fi
}

test_timeout_signals_root_without_ps
test_pid_reuse_metadata_is_enforced
test_supervisor_isolates_provider_group_without_mutating_caller
test_timeout_kills_term_resistant_descendant_without_ps
test_interruption_cleans_timeout_state_and_preserves_default_term
test_interruption_restores_returning_caller_trap

test_summary
