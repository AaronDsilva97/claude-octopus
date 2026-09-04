#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Caller process-group preservation"
log() { :; }
source "$PROJECT_ROOT/scripts/lib/heartbeat.sh"

test_case "preserve mode isolates the provider from the caller process group"
parent_pgid="$(ps -o pgid= -p $$ | tr -d ' ')"
child_pgid="$(OCTOPUS_PRESERVE_CALLER_PROCESS_GROUP=true run_with_timeout 5 sh -c 'ps -o pgid= -p $$ | tr -d " "')"
if [[ -n "$child_pgid" && "$child_pgid" != "$parent_pgid" ]]; then
    test_pass
else
    test_fail "provider was not isolated from caller PGID $parent_pgid: child=$child_pgid"
fi

test_case "preserve mode cleans up timed-out descendants"
tmpdir="$TEST_TMP_DIR/preserve-timeout"
mkdir -p "$tmpdir"
pidfile="$tmpdir/child.pid"
if (
    export "OCTOPUS_PRESERVE_CALLER_PROCESS_GROUP=true"
    run_with_timeout 1 sh -c 'sleep 30 & echo "$!" > "$1"; wait' sh "$pidfile" >/dev/null 2>&1
); then
    status=0
else
    status=$?
fi
child_pid="$(cat "$pidfile" 2>/dev/null || true)"
sleep 0.3
child_stat="$(ps -o stat= -p "$child_pid" 2>/dev/null | tr -d "[:space:]" || true)"
if [[ -n "$child_stat" && "$child_stat" != Z* ]]; then
    kill -KILL "$child_pid" 2>/dev/null || true
    test_fail "descendant survived preserve-mode timeout: $child_pid (stat=$child_stat)"
elif [[ "$status" -eq 124 ]]; then
    test_pass
else
    test_fail "unexpected timeout status: $status"
fi

test_case "preserve mode never delegates containment to GNU timeout"
fake_bin="$TEST_TMP_DIR/fake-timeout-bin"
timeout_marker="$TEST_TMP_DIR/system-timeout-used"
mkdir -p "$fake_bin"
for timeout_name in gtimeout timeout; do
    cat > "$fake_bin/$timeout_name" <<'SH'
#!/bin/sh
: > "$OCTO_TIMEOUT_MARKER"
exit 99
SH
    chmod +x "$fake_bin/$timeout_name"
done
if PATH="$fake_bin:$PATH" OCTO_TIMEOUT_MARKER="$timeout_marker" \
   OCTOPUS_PRESERVE_CALLER_PROCESS_GROUP=true \
   run_with_timeout 5 sh -c 'exit 0' >/dev/null 2>&1 && \
   [[ ! -e "$timeout_marker" ]]; then
    test_pass
else
    test_fail "preserve mode invoked an external timeout implementation"
fi

test_summary
