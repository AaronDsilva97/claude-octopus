#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"

log() { :; }
source "$PROJECT_ROOT/scripts/lib/providers.sh"

test_suite "Bounded Claude --bare authentication probe"

test_case "non-live test and remote probe suppression never launches Claude"
probe_marker="$TEST_TMP_DIR/claude-called"
claude() { : > "$probe_marker"; }
rc=0
OCTOPUS_SKIP_PROVIDER_PROBES=true _octo_bare_auth_probe >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 125 && ! -e "$probe_marker" ]]; then test_pass
else test_fail "suppressed probe rc=$rc launched=$([[ -e "$probe_marker" ]] && echo yes || echo no)"; fi
unset -f claude

test_case "probe keeps the TERM-to-KILL grace inside its total default budget"
read -r total_timeout term_timeout kill_grace <<< "$(_octo_bare_probe_budget 5)"
if [[ "$total_timeout" -eq 5 && "$term_timeout" -eq 3 && "$kill_grace" -eq 2 ]]; then
    test_pass
else
    test_fail "unexpected total-budget split: total=$total_timeout term=$term_timeout grace=$kill_grace"
fi

test_case "invalid and arbitrarily large timeout overrides are normalized before arithmetic"
invalid_budget="$(_octo_bare_probe_budget bogus)"
clamped_budget="$(_octo_bare_probe_budget 999999999999999999999999999999999999999)"
if [[ "$invalid_budget" == "5 3 2" && "$clamped_budget" == "30 28 2" ]]; then
    test_pass
else
    test_fail "timeout validation failed: invalid=$invalid_budget clamped=$clamped_budget"
fi

test_case "zero-padded positive timeout overrides retain their numeric value"
padded_budget="$(_octo_bare_probe_budget 00029)"
if [[ "$padded_budget" == "29 27 2" ]]; then
    test_pass
else
    test_fail "zero-padded timeout did not normalize to 29 seconds: budget=$padded_budget"
fi

test_case "one-second probe budgets use a hard cap without extending for grace"
short_budget="$(_octo_bare_probe_budget 1)"
if [[ "$short_budget" == "1 1 0" ]]; then
    test_pass
else
    test_fail "short timeout extended past the configured cap: budget=$short_budget"
fi

test_case "portable fallback hard-kills a TERM-ignoring probe at the total cap"
manual_bin="$TEST_TMP_DIR/manual-bin"
mkdir -p "$manual_bin"
ln -sf /bin/sleep "$manual_bin/sleep"
ln -sf /usr/bin/pkill "$manual_bin/pkill"
ln -sf "$(command -v mktemp)" "$manual_bin/mktemp"
ln -sf "$(command -v rm)" "$manual_bin/rm"
ln -sf "$(command -v cat)" "$manual_bin/cat"
if command -v setsid >/dev/null 2>&1; then
    ln -sf "$(command -v setsid)" "$manual_bin/setsid"
elif command -v perl >/dev/null 2>&1; then
    ln -sf "$(command -v perl)" "$manual_bin/perl"
fi
stubborn_probe="$TEST_TMP_DIR/stubborn-probe.sh"
cat > "$stubborn_probe" <<'SH'
#!/bin/sh
trap '' TERM
while :; do sleep 1; done
SH
chmod +x "$stubborn_probe"
SECONDS=0
rc=0
(
    PATH="$manual_bin"
    _octo_run_bare_probe_with_timeout 1 1 0 "$stubborn_probe" \
        >/dev/null 2>&1
) || rc=$?
elapsed=$SECONDS
if [[ "$rc" -ne 0 && "$elapsed" -le 2 ]]; then
    test_pass
else
    test_fail "portable fallback exceeded cap or lost failure: rc=$rc elapsed=${elapsed}s"
fi

test_case "portable fallback kills the complete probe process tree"
grandchild_pid_file="$TEST_TMP_DIR/grandchild.pid"
descendant_wrapper="$TEST_TMP_DIR/descendant-wrapper.sh"
descendant_probe="$TEST_TMP_DIR/descendant-probe.sh"
cat > "$descendant_wrapper" <<'SH'
#!/bin/sh
sleep 30 &
printf '%s\n' "$!" > "$OCTO_GRANDCHILD_PID_FILE"
wait
SH
cat > "$descendant_probe" <<'SH'
#!/bin/sh
trap '' TERM
"$OCTO_DESCENDANT_WRAPPER" &
wait
SH
chmod +x "$descendant_wrapper" "$descendant_probe"
export OCTO_GRANDCHILD_PID_FILE="$grandchild_pid_file"
export OCTO_DESCENDANT_WRAPPER="$descendant_wrapper"
rc=0
(
    PATH="$manual_bin"
    # Process creation can exceed one second on loaded macOS CI hosts. Give the
    # fixture enough time to publish its PID before asserting whole-tree kill.
    _octo_run_bare_probe_with_timeout 3 3 0 "$descendant_probe" \
        >/dev/null 2>&1
) || rc=$?
grandchild_pid=$(cat "$grandchild_pid_file" 2>/dev/null || true)
if [[ -n "$grandchild_pid" ]] && kill -0 "$grandchild_pid" 2>/dev/null; then
    kill -KILL "$grandchild_pid" 2>/dev/null || true
    wait "$grandchild_pid" 2>/dev/null || true
    test_fail "portable fallback left grandchild pid=$grandchild_pid running"
elif [[ "$rc" -ne 0 && -n "$grandchild_pid" ]]; then
    test_pass
else
    test_fail "portable fallback did not exercise descendant fixture: rc=$rc pid=$grandchild_pid"
fi

test_case "strict probe cleanup kills descendants after their wrapper exits cleanly"
early_child_pid_file="$TEST_TMP_DIR/early-child.pid"
early_exit_probe="$TEST_TMP_DIR/early-exit-probe.sh"
cat > "$early_exit_probe" <<'SH'
#!/bin/sh
sleep 30 &
printf '%s\n' "$!" > "$OCTO_EARLY_CHILD_PID_FILE"
exit 0
SH
chmod +x "$early_exit_probe"
export OCTO_EARLY_CHILD_PID_FILE="$early_child_pid_file"
rc=0
(
    PATH="$manual_bin"
    _octo_run_bare_probe_with_timeout 3 1 2 "$early_exit_probe" >/dev/null 2>&1
) || rc=$?
early_child_pid=$(cat "$early_child_pid_file" 2>/dev/null || true)
early_child_alive=false
if [[ "$early_child_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$early_child_pid" 2>/dev/null; then
    early_child_stat="$(ps -o stat= -p "$early_child_pid" 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$early_child_stat" && "$early_child_stat" != Z* ]] && early_child_alive=true
fi
if [[ "$rc" -eq 0 && -n "$early_child_pid" && "$early_child_alive" == false ]]; then
    test_pass
else
    [[ "$early_child_alive" == false ]] || kill -KILL "$early_child_pid" 2>/dev/null || true
    test_fail "clean wrapper exit left descendant running: rc=$rc pid=${early_child_pid:-missing}/$early_child_alive"
fi

test_case "a probe that exits zero from TERM still reports timeout"
term_success_probe="$TEST_TMP_DIR/term-success-probe.sh"
cat > "$term_success_probe" <<'SH'
#!/bin/sh
trap 'exit 0' TERM
while :; do sleep 1; done
SH
chmod +x "$term_success_probe"
SECONDS=0
rc=0
(
    PATH="$manual_bin"
    _octo_run_bare_probe_with_timeout 3 1 2 "$term_success_probe" >/dev/null 2>&1
) || rc=$?
elapsed=$SECONDS
if [[ "$rc" -eq 124 && "$elapsed" -le 3 ]]; then
    test_pass
else
    test_fail "TERM-handling probe hid its timeout: rc=$rc elapsed=${elapsed}s"
fi

test_case "caller interruption cleans the supervised probe process group"
interrupt_child_pid_file="$TEST_TMP_DIR/interrupted-child.pid"
interrupt_probe="$TEST_TMP_DIR/interrupted-probe.sh"
interrupt_runner="$TEST_TMP_DIR/interrupted-runner.sh"
cat > "$interrupt_probe" <<'SH'
#!/bin/sh
trap '' TERM
printf '%s\n' "$$" > "$OCTO_INTERRUPT_CHILD_PID_FILE"
while :; do sleep 1; done
SH
cat > "$interrupt_runner" <<'SH'
#!/usr/bin/env bash
log() { :; }
source "$OCTO_BOUNDED_PROBE_LIB"
_octo_run_bare_probe_with_timeout 30 28 2 "$OCTO_INTERRUPT_PROBE"
SH
chmod +x "$interrupt_probe" "$interrupt_runner"
OCTO_BOUNDED_PROBE_LIB="$PROJECT_ROOT/scripts/lib/bounded-probe.sh" \
OCTO_INTERRUPT_PROBE="$interrupt_probe" \
OCTO_INTERRUPT_CHILD_PID_FILE="$interrupt_child_pid_file" \
    "$interrupt_runner" >/dev/null 2>&1 &
interrupt_runner_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [[ -s "$interrupt_child_pid_file" ]] && break
    sleep 0.05
done
interrupt_child_pid="$(cat "$interrupt_child_pid_file" 2>/dev/null || true)"
kill -TERM "$interrupt_runner_pid" 2>/dev/null || true
interrupt_rc=0
wait "$interrupt_runner_pid" 2>/dev/null || interrupt_rc=$?
sleep 0.1
if [[ "$interrupt_child_pid" =~ ^[1-9][0-9]*$ ]] && \
   ! kill -0 "$interrupt_child_pid" 2>/dev/null && \
   [[ "$interrupt_rc" -eq 143 ]]; then
    test_pass
else
    [[ "$interrupt_child_pid" =~ ^[1-9][0-9]*$ ]] && kill -KILL "$interrupt_child_pid" 2>/dev/null || true
    test_fail "interrupted probe survived or returned the wrong status: rc=$interrupt_rc pid=${interrupt_child_pid:-missing}"
fi

test_case "non-live suite runner suppresses provider probes without changing live suites"
runner="$PROJECT_ROOT/tests/run-all-tests.sh"
if grep -Fq 'if [[ "$test_file" == "$SCRIPT_DIR/live/"* ]]' "$runner" &&
   grep -Fq 'OCTOPUS_SKIP_PROVIDER_PROBES=true bash "$test_file"' "$runner"; then
    test_pass
else
    test_fail "test runner does not isolate non-live provider probes from live suites"
fi

test_case "standalone doctor loads the bounded probe helper"
if bash -c 'source "$1"; declare -f _octo_bare_auth_probe >/dev/null' \
    _ "$PROJECT_ROOT/scripts/lib/doctor.sh"; then
    test_pass
else
    test_fail "lib/doctor.sh does not provide the bounded bare-auth probe standalone"
fi

test_summary
