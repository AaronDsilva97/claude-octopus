#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# lib/heartbeat.sh — Heartbeat monitoring, dynamic timeouts, portable timeout
# Extracted from orchestrate.sh (v8.19.0 heartbeat + v7.16.0 timeout)
# ═══════════════════════════════════════════════════════════════════════════════

# Opt-in lifecycle event stream — no-op unless OCTO_EVENT_LOG is set. Sourced
# guarded so heartbeat stays usable even if events.sh is absent.
_octo_heartbeat_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "${_octo_heartbeat_lib_dir}/events.sh" 2>/dev/null || true

start_heartbeat_monitor() {
    local pid="$1"
    local task_id="$2"

    local heartbeat_dir="${WORKSPACE_DIR}/.octo/agents"
    mkdir -p "$heartbeat_dir"
    local heartbeat_file="$heartbeat_dir/${pid}.heartbeat"

    # Background process: touch heartbeat every 30s, self-terminate when PID dies
    (
        while kill -0 "$pid" 2>/dev/null; do
            touch "$heartbeat_file"
            sleep 30
        done
        rm -f "$heartbeat_file"
    ) &
    disown

    log DEBUG "Heartbeat monitor started for PID $pid (task: $task_id)"
}

check_agent_heartbeat() {
    local pid="$1"

    local heartbeat_file="${WORKSPACE_DIR}/.octo/agents/${pid}.heartbeat"

    if [[ ! -f "$heartbeat_file" ]]; then
        echo "missing"
        return
    fi

    # Get file modification time (macOS vs Linux compatible)
    local mod_time
    if stat -f %m "$heartbeat_file" &>/dev/null; then
        # macOS
        mod_time=$(stat -f %m "$heartbeat_file")
    else
        # Linux
        mod_time=$(stat -c %Y "$heartbeat_file")
    fi

    local now
    now=$(date +%s)
    local age=$((now - mod_time))

    if [[ $age -gt 90 ]]; then
        echo "stale"
    else
        echo "alive"
    fi
}

compute_dynamic_timeout() {
    local task_type="${1:-standard}"
    local prompt="${2:-}"
    local agent_type="${3:-}"  # v9.2.0: optional provider for per-provider caps

    # Env override takes precedence
    if [[ -n "${OCTOPUS_AGENT_TIMEOUT:-}" ]]; then
        echo "$OCTOPUS_AGENT_TIMEOUT"
        return
    fi

    # v9.2.0: Provider-specific timeout caps (OctoBench data)
    # Codex: consistently 120-183s, cap at 150s for probe tasks
    # Antigravity: cap at 90s for probe tasks
    # Claude-sonnet: consistently 35-46s, cap at 60s for probe tasks
    local provider_cap=""
    case "$agent_type" in
        codex*)     provider_cap=150 ;;
        gemini*|agy*|antigravity) provider_cap=90 ;;
        qwen*)      provider_cap=90 ;;   # oco-dar: Gemini-CLI fork — same profile; cap auth-hang risk
        claude-sonnet*|sonnet*) provider_cap=60 ;;
        perplexity*) provider_cap=45 ;;
    esac

    # Response mode mapping
    local response_mode="${OCTOPUS_RESPONSE_MODE:-auto}"
    case "$response_mode" in
        direct|lightweight)
            echo "60"
            return
            ;;
    esac

    # v8.40.0: When CC has memory leak fixes (v2.1.63+), long sessions are stable —
    # allow longer timeouts for complex tasks since agent sessions won't degrade
    local leak_safe_boost=0
    if [[ "$SUPPORTS_MEMORY_LEAK_FIXES" == "true" ]]; then
        leak_safe_boost=60
    fi

    # Task type mapping
    case "$task_type" in
        direct|lightweight|trivial)
            echo "60"
            ;;
        full|premium|complex)
            echo "$((300 + leak_safe_boost))"
            ;;
        crossfire|debate)
            echo "$((180 + leak_safe_boost))"
            ;;
        security|audit)
            echo "$((240 + leak_safe_boost))"
            ;;
        *)
            local base_timeout=$((120 + leak_safe_boost))
            # Apply provider cap if set and lower than task-based timeout
            if [[ -n "$provider_cap" && "$provider_cap" -lt "$base_timeout" ]]; then
                echo "$provider_cap"
            else
                echo "$base_timeout"
            fi
            ;;
    esac
}

cleanup_heartbeat() {
    local pid="$1"
    rm -f "${WORKSPACE_DIR}/.octo/agents/${pid}.heartbeat"
}


# Run an external command under GNU timeout while preserving the caller process
# group. timeout --foreground intentionally stops managing a separate command
# process group, so this wrapper owns descendant cleanup on TERM/INT/HUP without
# ever signalling the caller's PGID.
_run_with_timeout_preserving_process_group() {
    local timeout_bin="$1"
    local timeout_secs="$2"
    shift 2

    "$timeout_bin" --foreground "$timeout_secs" bash -c '
        set +e
        _octo_collect_descendants() {
            local parent="$1" child
            while IFS= read -r child; do
                child="${child//[[:space:]]/}"
                [[ -n "$child" ]] || continue
                _octo_collect_descendants "$child"
                _octo_descendants+=("$child")
            done < <(ps -eo pid=,ppid= | while read -r pid ppid; do [[ "$ppid" == "$parent" ]] && echo "$pid"; done)
        }
        _octo_cleanup_descendants() {
            _octo_descendants=()
            _octo_collect_descendants "$child_pid"
            if ((${#_octo_descendants[@]})); then
                kill -TERM "${_octo_descendants[@]}" 2>/dev/null || true
            fi
            kill -TERM "$child_pid" 2>/dev/null || true

            # Match timeout -k 10 semantics: give the provider subtree the full
            # 10-second TERM grace period before escalating remaining processes.
            _octo_grace_deadline=$((SECONDS + 10))
            while (( SECONDS < _octo_grace_deadline )); do
                _octo_any_alive=false
                kill -0 "$child_pid" 2>/dev/null && _octo_any_alive=true
                for _octo_pid in "${_octo_descendants[@]}"; do
                    if kill -0 "$_octo_pid" 2>/dev/null; then
                        _octo_any_alive=true
                        break
                    fi
                done
                [[ "$_octo_any_alive" == "false" ]] && break
                sleep 0.1
            done

            _octo_descendants=()
            _octo_collect_descendants "$child_pid"
            if ((${#_octo_descendants[@]})); then
                kill -KILL "${_octo_descendants[@]}" 2>/dev/null || true
            fi
            kill -KILL "$child_pid" 2>/dev/null || true
            wait "$child_pid" 2>/dev/null || true
        }
        _octo_on_signal() {
            trap - TERM INT HUP
            _octo_cleanup_descendants
            exit 143
        }
        trap _octo_on_signal TERM INT HUP
        "$@" <&0 &
        child_pid=$!
        wait "$child_pid"
        status=$?
        trap - TERM INT HUP
        exit "$status"
    ' bash "$@"
}

# Snapshot a process tree before signalling it. A parent can exit and reparent
# its descendants immediately after TERM, so discovering children after the
# root is gone is too late for reliable cleanup.
_octo_timeout_process_tree_depth_first() {
    local root_pid="$1" include_without_metadata="${2:-false}" child_pid process_started
    while IFS= read -r child_pid; do
        child_pid="${child_pid//[[:space:]]/}"
        [[ "$child_pid" =~ ^[1-9][0-9]*$ ]] || continue
        _octo_timeout_process_tree_depth_first "$child_pid" false
    done < <(ps -eo pid=,ppid= 2>/dev/null | awk -v parent="$root_pid" '$2 == parent { print $1 }')
    # The direct root PID comes from `$!`, so it remains actionable even when a
    # restricted harness denies process enumeration. Start metadata is an
    # additional PID-reuse guard when available, not a prerequisite to signal
    # the process we just launched. Descendants remain metadata-gated.
    if process_started="$(ps -o lstart= -p "$root_pid" 2>/dev/null)" && [[ -n "$process_started" ]]; then
        printf '%s\t%s\n' "$root_pid" "$process_started"
    elif [[ "$include_without_metadata" == "true" ]]; then
        printf '%s\t\n' "$root_pid"
    fi
}

_octo_timeout_pid_is_running() {
    local pid="$1" expected_started="${2:-}" process_stat process_started
    kill -0 "$pid" 2>/dev/null || return 1
    if process_stat="$(ps -o stat= -p "$pid" 2>/dev/null)"; then
        [[ "$process_stat" != *Z* ]] || return 1
    elif [[ -n "$expected_started" ]]; then
        # If a snapshot had start metadata, never signal without proving that
        # the PID still identifies the same process.
        return 1
    fi
    [[ -z "$expected_started" ]] && return 0
    process_started="$(ps -o lstart= -p "$pid" 2>/dev/null)" || return 1
    [[ "$process_started" == "$expected_started" ]]
}

_octo_timeout_signal_snapshot() {
    local signal_name="$1" process_tree="$2" target_pid process_started
    while IFS=$'\t' read -r target_pid process_started; do
        [[ "$target_pid" =~ ^[1-9][0-9]*$ && "$target_pid" != "1" ]] || continue
        _octo_timeout_pid_is_running "$target_pid" "$process_started" || continue
        kill -"$signal_name" "$target_pid" 2>/dev/null || true
    done <<< "$process_tree"
}

_octo_timeout_signal_status() {
    case "$1" in
        HUP)  printf '%s\n' 129 ;;
        INT)  printf '%s\n' 130 ;;
        TERM) printf '%s\n' 143 ;;
        *)    printf '%s\n' 1 ;;
    esac
}

_octo_timeout_restore_trap() {
    local signal_name="$1" saved_trap="$2"
    if [[ -n "$saved_trap" ]]; then
        eval "$saved_trap"
    else
        trap - "$signal_name"
    fi
}

_octo_timeout_restore_signal_traps() {
    _octo_timeout_restore_trap INT "$1"
    _octo_timeout_restore_trap TERM "$2"
    _octo_timeout_restore_trap HUP "$3"
}

# Ask a direct child to signal its actual parent. Bash 3.2 has no BASHPID, and
# $$ intentionally remains the top-level shell PID inside subshells, so neither
# is safe when this library itself runs in a background shell.
_octo_timeout_redeliver_signal() {
    /bin/sh -c 'kill -s "$1" "$PPID"' octo-signal "$1"
}

_octo_timeout_process_group_exists() {
    local process_group="$1"
    [[ "$process_group" =~ ^[1-9][0-9]*$ && "$process_group" != "1" ]] || return 1
    kill -0 -- "-$process_group" 2>/dev/null
}

_octo_timeout_job_is_running() {
    local expected_pid="$1" job_pid
    while IFS= read -r job_pid; do
        [[ "$job_pid" == "$expected_pid" ]] && return 0
    done < <(jobs -pr 2>/dev/null)
    return 1
}

_octo_timeout_stop_process_group() {
    local process_group="$1" initial_signal="$2" allow_term_grace="$3"
    local grace_deadline
    [[ "$process_group" =~ ^[1-9][0-9]*$ && "$process_group" != "1" ]] || return 0

    kill -"$initial_signal" -- "-$process_group" 2>/dev/null || true
    if [[ "$allow_term_grace" == "true" ]]; then
        # Match timeout -k 10: allow the provider group ten seconds to perform
        # normal TERM cleanup before forcing out resistant descendants.
        # Bound the grace by Bash's built-in wall clock. Counting external sleep
        # processes can stretch a nominal ten-second grace on a busy macOS runner.
        grace_deadline=$((SECONDS + 10))
        while (( SECONDS < grace_deadline )); do
            _octo_timeout_process_group_exists "$process_group" || break
            sleep 0.1
        done
    else
        # An interrupted caller is already unwinding. Give ordinary handlers a
        # scheduling turn, then guarantee that no provider descendant survives.
        sleep 0.1
    fi
    kill -KILL -- "-$process_group" 2>/dev/null || true
}

_octo_timeout_supervisor_handle_signal() {
    local signal_name="$1" exit_status initial_signal allow_term_grace=false
    exit_status="$(_octo_timeout_signal_status "$signal_name")"
    initial_signal="$signal_name"
    if [[ "$signal_name" == "USR1" ]]; then
        exit_status=124
        initial_signal=TERM
        allow_term_grace=true
    fi

    # Prevent nested signals from interrupting cleanup. Reap the timer first to
    # suppress Bash job-status output, then terminate the private provider PGID.
    trap '' USR1 TERM INT HUP
    if [[ "${timer_pid:-}" =~ ^[1-9][0-9]*$ ]]; then
        kill -KILL -- "-$timer_pid" 2>/dev/null || true
        wait "$timer_pid" 2>/dev/null || true
    fi
    if [[ "${provider_pid:-}" =~ ^[1-9][0-9]*$ ]]; then
        _octo_timeout_stop_process_group "$provider_pid" "$initial_signal" "$allow_term_grace"
        wait "$provider_pid" 2>/dev/null || true
    fi
    exit "$exit_status"
}

# Bash 3.2/macOS-compatible timeout supervisor. Monitor mode gives the provider
# wrapper a private process group; monitor mode is disabled again inside that
# wrapper so its full descendant tree remains in the same group. The wrapper PID
# stays an unreaped child until cleanup completes, preventing PGID reuse even if
# process metadata cannot be read with ps.
_octo_timeout_supervisor() {
    local timeout_secs="$1"
    shift
    local provider_pid="" timer_pid="" provider_status=0

    set -m
    trap '_octo_timeout_supervisor_handle_signal USR1' USR1
    trap '_octo_timeout_supervisor_handle_signal TERM' TERM
    trap '_octo_timeout_supervisor_handle_signal HUP' HUP

    (
        set +m
        "$@" <&0
    ) <&0 &
    provider_pid=$!

    # This must be a directly executed child, not command substitution: its
    # PPID is the supervisor's real PID even in Bash 3.2 subshells.
    /bin/sh -c 'sleep "$1"; kill -USR1 "$PPID"' octo-timer "$timeout_secs" &
    timer_pid=$!

    if wait "$provider_pid" 2>/dev/null; then
        provider_status=0
    else
        provider_status=$?
    fi

    trap '' USR1 TERM INT HUP
    kill -KILL -- "-$timer_pid" 2>/dev/null || true
    wait "$timer_pid" 2>/dev/null || true
    trap - USR1 TERM INT HUP
    set +m
    return "$provider_status"
}

_octo_timeout_handle_caller_signal() {
    local signal_name="$1"
    _octo_timeout_interrupted_status="$(_octo_timeout_signal_status "$signal_name")"

    trap '' TERM INT HUP
    if [[ "${_octo_timeout_supervisor_pid:-}" =~ ^[1-9][0-9]*$ ]] &&
       _octo_timeout_job_is_running "$_octo_timeout_supervisor_pid"; then
        # TERM is always actionable for an asynchronous Bash child; INT may be
        # inherited as ignored when the caller has job control disabled. The
        # jobs check proves this PID is still our live child before signalling.
        kill -TERM "$_octo_timeout_supervisor_pid" 2>/dev/null || true
        wait "$_octo_timeout_supervisor_pid" 2>/dev/null || true
    fi
    _octo_timeout_restore_signal_traps \
        "$_octo_timeout_previous_int_trap" \
        "$_octo_timeout_previous_term_trap" \
        "$_octo_timeout_previous_hup_trap"
    _octo_timeout_redeliver_signal "$signal_name"
    return "$_octo_timeout_interrupted_status"
}

# Portable timeout function (works on macOS and Linux).
# Prefers system timeout commands unless the internal --portable-supervisor
# option is requested by a caller that must process signals while it waits.
run_with_timeout() {
    local force_portable_supervisor=false
    if [[ "${1:-}" == "--portable-supervisor" ]]; then
        force_portable_supervisor=true
        shift
    fi
    local timeout_secs="$1"
    shift

    local exit_code
    local _octo_cmd_label="${1:-unknown}"

    if declare -f octo_event_emit >/dev/null 2>&1; then
        octo_event_emit "dispatch.start" command="$_octo_cmd_label" timeout="$timeout_secs" || true
    fi

    # timeout_secs=0 means no absolute timeout. Callers that choose it must set
    # OCTOPUS_UNBOUNDED_EXECUTION_SUPERVISED to document the external heartbeat,
    # stall, or workflow-level watchdog responsible for recovery.
    if [[ "$timeout_secs" =~ ^[0-9]+$ ]] && [[ "$timeout_secs" -eq 0 ]]; then
        "$@"
        exit_code=$?
        if declare -f octo_event_emit >/dev/null 2>&1; then
            local _octo_outcome="ok"
            [[ $exit_code -eq 0 ]] || _octo_outcome="error"
            octo_event_emit "dispatch.end" command="$_octo_cmd_label" exit_code="$exit_code" outcome="$_octo_outcome" timeout="none" || true
        fi
        return "$exit_code"
    fi

    # v9.20.1: Detect if command is a shell function (e.g. perplexity_execute,
    # openrouter_execute). External timeout/gtimeout can only exec binaries —
    # shell functions require the in-process fallback path. (#255)
    local _cmd_is_function=false
    if [[ "$(type -t "$1" 2>/dev/null)" == "function" ]]; then
        _cmd_is_function=true
    fi

    # Use gtimeout (GNU) or timeout if available AND command is an external binary.
    # oco-dar: `-k 10` escalates to SIGKILL 10s after the initial SIGTERM. A
    # provider that catches SIGTERM and stalls (e.g. node mid-OAuth device-flow)
    # would otherwise outlive the timeout — that is exactly how an expired-token
    # qwen probe hung ~10min instead of dying at the per-agent cap.
    if [[ "$force_portable_supervisor" == "false" && "$_cmd_is_function" == "false" ]] &&
       command -v gtimeout &>/dev/null; then
        if [[ "${OCTOPUS_PRESERVE_CALLER_PROCESS_GROUP:-false}" == "true" ]]; then
            _run_with_timeout_preserving_process_group gtimeout "$timeout_secs" "$@"
        else
            gtimeout -k 10 "$timeout_secs" "$@"
        fi
        exit_code=$?
    elif [[ "$force_portable_supervisor" == "false" && "$_cmd_is_function" == "false" ]] &&
         command -v timeout &>/dev/null; then
        if [[ "${OCTOPUS_PRESERVE_CALLER_PROCESS_GROUP:-false}" == "true" ]]; then
            _run_with_timeout_preserving_process_group timeout "$timeout_secs" "$@"
        else
            timeout -k 10 "$timeout_secs" "$@"
        fi
        exit_code=$?
    else
        # The Bash 3.2 fallback runs a supervisor asynchronously so this shell
        # can trap interruption while waiting. The provider itself receives the
        # caller's stdin through the private process-group wrapper.
        local _octo_timeout_previous_int_trap _octo_timeout_previous_term_trap
        local _octo_timeout_previous_hup_trap _octo_timeout_supervisor_pid=""
        local _octo_timeout_interrupted_status=0
        _octo_timeout_previous_int_trap="$(trap -p INT)"
        _octo_timeout_previous_term_trap="$(trap -p TERM)"
        _octo_timeout_previous_hup_trap="$(trap -p HUP)"
        trap '_octo_timeout_handle_caller_signal INT' INT
        trap '_octo_timeout_handle_caller_signal TERM' TERM
        trap '_octo_timeout_handle_caller_signal HUP' HUP

        _octo_timeout_supervisor "$timeout_secs" "$@" <&0 &
        _octo_timeout_supervisor_pid=$!
        if [[ "$_octo_timeout_interrupted_status" -ne 0 ]]; then
            # A signal can arrive after the temporary traps are installed but
            # before `$!` is assigned. The handler records it; finish cleanup
            # here once the supervisor PID is available.
            kill -TERM "$_octo_timeout_supervisor_pid" 2>/dev/null || true
            wait "$_octo_timeout_supervisor_pid" 2>/dev/null || true
            return "$_octo_timeout_interrupted_status"
        fi
        if wait "$_octo_timeout_supervisor_pid" 2>/dev/null; then
            exit_code=0
        else
            exit_code=$?
        fi

        if [[ "$_octo_timeout_interrupted_status" -ne 0 ]]; then
            # The signal handler has already restored (and re-delivered to) the
            # caller's disposition. A nested trap may have restored another
            # outer trap, so do not overwrite it here.
            return "$_octo_timeout_interrupted_status"
        fi
        _octo_timeout_restore_signal_traps \
            "$_octo_timeout_previous_int_trap" \
            "$_octo_timeout_previous_term_trap" \
            "$_octo_timeout_previous_hup_trap"
    fi

    # Enhanced timeout error messaging (v7.16.0 Feature 3)
    if [[ $exit_code -eq 124 ]] || [[ $exit_code -eq 143 ]]; then
        local timeout_mins=$((timeout_secs / 60))
        local recommended_timeout=$((timeout_secs * 2))
        local recommended_mins=$((recommended_timeout / 60))

        log ERROR "Operation timed out after ${timeout_secs}s (${timeout_mins}m)"
        echo "" >&2
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
        echo "⚠️  TIMEOUT EXCEEDED" >&2
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
        echo "" >&2
        echo "Operation exceeded the ${timeout_secs}s (${timeout_mins}m) timeout limit." >&2
        echo "" >&2
        echo "💡 Possible solutions:" >&2
        echo "   1. Increase timeout: --timeout ${recommended_timeout} (${recommended_mins}m)" >&2
        echo "   2. Simplify the prompt to reduce processing time" >&2
        echo "   3. Check provider API status for slowness" >&2
        echo "" >&2
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
        if declare -f octo_event_emit >/dev/null 2>&1; then
            octo_event_emit "dispatch.timeout" command="$_octo_cmd_label" timeout="$timeout_secs" exit_code="$exit_code" || true
        fi
        return 124
    fi

    if declare -f octo_event_emit >/dev/null 2>&1; then
        local _octo_outcome="ok"
        [[ $exit_code -eq 0 ]] || _octo_outcome="error"
        octo_event_emit "dispatch.end" command="$_octo_cmd_label" exit_code="$exit_code" outcome="$_octo_outcome" || true
    fi

    return $exit_code
}

# Capture provider stdin/stdout through files rather than a tee pipeline.
# Provider CLIs may spawn hooks or helpers that outlive the main process while
# retaining stdout. If stdout is a pipe, tee never receives EOF and the
# completed provider remains stuck until the fleet watchdog fires (#892).
octopus_capture_provider_output() {
    local prompt="$1"
    local timeout_secs="$2"
    local temp_input_hint="$3"
    local temp_input=""
    local raw_output="$4"
    local temp_errors="$5"
    shift 5

    temp_input="$(umask 077 && mktemp "${temp_input_hint}.XXXXXX")" || return 1
    if ! printf '%s' "$prompt" > "$temp_input"; then
        rm -f "$temp_input"
        return 1
    fi

    local exit_code=0
    if OCTOPUS_UNBOUNDED_EXECUTION_SUPERVISED="spawn-agent-heartbeat" \
        OCTOPUS_PRESERVE_CALLER_PROCESS_GROUP="true" \
        run_with_timeout "$timeout_secs" "$@" < "$temp_input" > "$raw_output" 2> "$temp_errors"; then
        exit_code=0
    else
        exit_code=$?
    fi

    rm -f "$temp_input"
    return "$exit_code"
}
