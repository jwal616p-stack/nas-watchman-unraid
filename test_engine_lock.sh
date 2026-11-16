#!/usr/bin/env bash
# Regression (found on JohnsVault 2026-11-14): an engine stopped while in its 60 s sleep left the sleep
# holding worker.lock, so the next engine (reload/restart) exited "Watchman worker already running."
# Offline: stub telemetry, no Discord, no NAS paths.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
cleanup() { pkill -f "$T/" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/bin" "$T/state"
printf '#!/bin/sh\nexit 127\n' > "$T/bin/nvidia-smi"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/docker"; chmod 755 "$T/bin/"*
cp "$ROOT/watchman_engine.sh" "$ROOT/watchman_local_metrics.sh" "$T/"
export PATH=$T/bin:$PATH WATCHMAN_STATE_DIR=$T/state WATCHMAN_WEBHOOK_FILE=$T/none WATCHMAN_SYSLOG=$T/none \
       WATCHMAN_DISKS_INI=$T/none WATCHMAN_VAR_INI=$T/none WATCHMAN_METRICS_MODE=local WATCHMAN_DISKS='[]' WATCHMAN_CONTAINERS='[]'
start_engine() { bash "$T/watchman_engine.sh" --watch > "$T/engine-$1.log" 2>&1 & echo $!; }
sleeping_child() { pgrep -P "$1" -x sleep || true; }
waitfor() { local i; for i in $(seq ${3:-100}); do eval "$1" && return 0; sleep 0.1; done; echo "FAIL: timed out: $2"; cat "$T"/engine-*.log; exit 1; }

E1=$(start_engine 1)
waitfor '[[ -n $(sleeping_child $E1) ]]' 'first engine reaches its sleep'
S1=$(sleeping_child "$E1")
kill -TERM "$E1"; waitfor '! kill -0 $E1 2>/dev/null' 'first engine exits on TERM'
grep -q 'stopped cleanly' "$T/engine-1.log" || { echo 'FAIL: no clean stop message'; exit 1; }
waitfor '! kill -0 $S1 2>/dev/null' 'leftover sleep is gone'
flock -n "$T/state/worker.lock" true || { echo 'FAIL: worker.lock still held after engine stopped'; exit 1; }
echo 'PASS: engine stopped mid-sleep releases worker.lock and leaves no sleep behind'

E2=$(start_engine 2)
waitfor '[[ -n $(sleeping_child $E2) ]]' 'second engine starts and runs (immediate restart)'
grep -q 'already running' "$T/engine-2.log" && { echo 'FAIL: second engine refused'; exit 1; }
echo 'PASS: immediate restart after stop succeeds'

E3=$(start_engine 3)
sleep 1
kill -0 "$E3" 2>/dev/null || { echo 'FAIL: duplicate gave up instead of waiting'; exit 1; }
waitfor '! kill -0 $E3 2>/dev/null' 'duplicate engine gives up after waiting (<=15 s)' 250
grep -q 'already running' "$T/engine-3.log" || { echo 'FAIL: duplicate engine was not refused'; exit 1; }
kill -0 "$E2" || { echo 'FAIL: running engine was disturbed'; exit 1; }
echo 'PASS: a real duplicate still refuses (after a short wait) and does not disturb the running engine'
kill -TERM "$E2"; waitfor '! kill -0 $E2 2>/dev/null' 'cleanup'
echo '3 engine-lock scenarios passed.'
