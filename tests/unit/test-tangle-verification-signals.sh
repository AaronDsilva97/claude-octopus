#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "tangle verification signals"
WORKFLOWS="$PROJECT_ROOT/scripts/lib/workflows.sh"

for signal in INT TERM; do
    test_case "verification cleanup invokes saved $signal trap and cannot resume"
    marker="$TEST_TMP_DIR/caller-${signal}.marker"
    exit_marker="$TEST_TMP_DIR/caller-${signal}-exit.marker"
    continued="$TEST_TMP_DIR/continued-${signal}.marker"
    child="$TEST_TMP_DIR/verify-${signal}.sh"
    cat > "$child" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
WORKFLOWS="$1"
MARKER="$2"
EXIT_MARKER="$3"
CONTINUED="$4"
SIGNAL="$5"
source "$WORKFLOWS"
log() { :; }
trap 'printf "caller-exit\n" > "$EXIT_MARKER"' EXIT
trap 'printf "caller-signal\n" > "$MARKER"' "$SIGNAL"
TANGLE_VERIFY_PREV_EXIT_TRAP=$(trap -p EXIT)
TANGLE_VERIFY_PREV_INT_TRAP=$(trap -p INT)
TANGLE_VERIFY_PREV_TERM_TRAP=$(trap -p TERM)
trap "tangle_handle_verification_signal $SIGNAL" "$SIGNAL"
kill -s "$SIGNAL" "$$"
printf 'resumed\n' > "$CONTINUED"
CHILD
    chmod +x "$child"
    set +e
    bash "$child" "$WORKFLOWS" "$marker" "$exit_marker" "$continued" "$signal"
    rc=$?
    set -e
    expected=143
    [[ "$signal" == "INT" ]] && expected=130
    if [[ "$rc" -eq "$expected" ]] && [[ -f "$marker" ]] && [[ -f "$exit_marker" ]] && [[ ! -e "$continued" ]]; then
        test_pass
    else
        test_fail "$signal handler rc=$rc expected=$expected marker=$(test -f "$marker" && echo yes || echo no) exit_marker=$(test -f "$exit_marker" && echo yes || echo no) continued=$(test -e "$continued" && echo yes || echo no)"
    fi
done

test_case "saved signal trap receives the interrupted function arguments"
marker="$TEST_TMP_DIR/caller-argument.marker"
child="$TEST_TMP_DIR/verify-caller-argument.sh"
cat > "$child" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
WORKFLOWS="$1"
MARKER="$2"
source "$WORKFLOWS"
log() { :; }
trap 'printf "%s\n" "$1" > "$MARKER"' INT
TANGLE_VERIFY_PREV_EXIT_TRAP=$(trap -p EXIT)
TANGLE_VERIFY_PREV_INT_TRAP=$(trap -p INT)
TANGLE_VERIFY_PREV_TERM_TRAP=$(trap -p TERM)
trap 'tangle_handle_verification_signal INT "$@"' INT
function_with_signal() {
    kill -INT "$$"
}
function_with_signal preserved-argument
CHILD
chmod +x "$child"
set +e
bash "$child" "$WORKFLOWS" "$marker"
rc=$?
set -e
if [[ "$rc" -eq 130 && "$(< "$marker")" == "preserved-argument" ]]; then
    test_pass
else
    test_fail "saved trap saw the handler signal instead of caller argument: rc=$rc value=$(< "$marker" 2>/dev/null || echo missing)"
fi

for signal in INT TERM; do
    for trap_mode in return exit; do
        test_case "saved $signal trap cannot override signal status with $trap_mode"
        marker="$TEST_TMP_DIR/caller-${signal}-${trap_mode}.marker"
        continued="$TEST_TMP_DIR/continued-${signal}-${trap_mode}.marker"
        child="$TEST_TMP_DIR/verify-${signal}-${trap_mode}.sh"
        cat > "$child" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
WORKFLOWS="$1"
MARKER="$2"
CONTINUED="$3"
SIGNAL="$4"
TRAP_MODE="$5"
source "$WORKFLOWS"
log() { :; }
if [[ "$TRAP_MODE" == "return" ]]; then
    trap 'printf "caller-signal\n" > "$MARKER"; return 0' "$SIGNAL"
else
    trap 'printf "caller-signal\n" > "$MARKER"; exit 1' "$SIGNAL"
fi
TANGLE_VERIFY_PREV_EXIT_TRAP=$(trap -p EXIT)
TANGLE_VERIFY_PREV_INT_TRAP=$(trap -p INT)
TANGLE_VERIFY_PREV_TERM_TRAP=$(trap -p TERM)
trap "tangle_handle_verification_signal $SIGNAL" "$SIGNAL"
kill -s "$SIGNAL" "$$"
printf 'resumed\n' > "$CONTINUED"
CHILD
        chmod +x "$child"
        set +e
        bash "$child" "$WORKFLOWS" "$marker" "$continued" "$signal" "$trap_mode"
        rc=$?
        set -e
        expected=143
        [[ "$signal" == "INT" ]] && expected=130
        if [[ "$rc" -eq "$expected" ]] && [[ -f "$marker" ]] && [[ ! -e "$continued" ]]; then
            test_pass
        else
            test_fail "$signal/$trap_mode handler rc=$rc expected=$expected marker=$(test -f "$marker" && echo yes || echo no) continued=$(test -e "$continued" && echo yes || echo no)"
        fi
    done
done

test_summary
