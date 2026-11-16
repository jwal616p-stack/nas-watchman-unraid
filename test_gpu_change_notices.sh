#!/usr/bin/env bash
# Offline GPU-configuration change regression: fixture metrics only, no Discord, no nvidia-smi.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export WATCHMAN_STATE_DIR
WATCHMAN_STATE_DIR=$(mktemp -d)
trap 'rm -rf "$WATCHMAN_STATE_DIR"' EXIT
export WATCHMAN_WEBHOOK_FILE="$WATCHMAN_STATE_DIR/nonexistent-webhook"
export WATCHMAN_SYSLOG="$WATCHMAN_STATE_DIR/nonexistent-syslog"
export WATCHMAN_METRICS_MODE=local WATCHMAN_CONTAINERS='[]' WATCHMAN_DISKS='[]'
source <(sed '/^collect || exit 1$/,$d' "$ROOT/watchman_engine.sh")
trap 'rm -rf "$WORK" "$WATCHMAN_STATE_DIR"' EXIT
NOTICES="$WATCHMAN_STATE_DIR/notices"
: > "$NOTICES"
FAIL_SEND=0
send() { (( FAIL_SEND == 0 )) || return 1; printf '%s\n' "$1" >> "$NOTICES"; }
G0='{"index":0,"available":true,"temperature_c":41,"uuid":"GPU-2060-aaaa-secret","bus_id":"00000000:01:00.0","name":"NVIDIA GeForce RTX 2060"}'
G1='{"index":1,"available":true,"temperature_c":46,"uuid":"GPU-3060-bbbb-secret","bus_id":"00000000:02:00.0","name":"NVIDIA GeForce RTX 3060"}'
G1_AS_0='{"index":0,"available":true,"temperature_c":46,"uuid":"GPU-3060-bbbb-secret","bus_id":"00000000:02:00.0","name":"NVIDIA GeForce RTX 3060"}'
G0_AS_1='{"index":1,"available":true,"temperature_c":41,"uuid":"GPU-2060-aaaa-secret","bus_id":"00000000:01:00.0","name":"NVIDIA GeForce RTX 2060"}'
metrics() {
  local err=null; [[ $1 == error ]] && err='"timed out after 3 s"'
  printf '{"gpu_query":"%s","gpu_error":%s,"gpus":[%s]}\n' "$1" "$err" "${2:-}" > "$WORK/metrics"; scan_gpu_changes; }
count() { grep -c '^GPU configuration changed' "$NOTICES" || true; }
expect() { local n; n=$(count); [[ $n -eq $1 ]] || { echo "FAIL ($2): expected $1 notices, got $n"; cat "$NOTICES"; exit 1; }; }
has() { grep -Fq -- "$1" "$NOTICES" || { echo "FAIL: missing: $1"; cat "$NOTICES"; exit 1; }; }

metrics ok "$G0,$G1"; expect 0 'baseline'
metrics ok "$G0,$G1"; expect 0 'unchanged'
metrics ok "$G1_AS_0,$G0_AS_1"; expect 0 'renumbered'
echo 'PASS: first run silent; unchanged and re-numbered cards are quiet'

metrics ok "$G0"; expect 1 'card vanished'
has 'GPU configuration changed: 2 card(s) before, 1 now.'
has 'GPU REMOVED: NVIDIA GeForce RTX 3060 (PCI 02:00.0) no longer reported.'
metrics ok "$G0"; expect 1 'no repeat'
echo 'PASS: vanished card notified once by model and PCI slot'

metrics ok "$G0,$G1"; expect 2 'card back'
has 'GPU ADDED: NVIDIA GeForce RTX 3060 (PCI 02:00.0) now reported.'
echo 'PASS: returning card notified once'

metrics error; expect 2 'one failed query'
metrics ok "$G0,$G1"; expect 2 'recovered before second failure'
metrics error; metrics error; expect 3 'two failed queries'
has 'nvidia-smi query FAILED (timed out after 3 s); GPU state unknown on two consecutive checks.'
metrics error; expect 3 'no repeat while still failing'
metrics ok "$G0,$G1"; expect 4 'driver back'
echo 'PASS: single query failure ignored; two failures in a row notified once, with the reason; recovery notified'

metrics none; metrics none; expect 5 'zero GPUs'
has 'nvidia-smi ran successfully but reported ZERO GPUs on two consecutive checks.'
metrics ok "$G0,$G1"; expect 6 'GPUs back'
echo 'PASS: successful query with zero GPUs is reported differently from a failed query'

metrics absent; metrics absent; expect 7 'nvidia-smi gone'
has 'nvidia-smi is not installed or not on PATH on two consecutive checks.'
metrics ok "$G0,$G1"; expect 8 'nvidia-smi back'
echo 'PASS: nvidia-smi missing notified after two checks'

FAIL_SEND=1; metrics ok "$G0" || true; expect 8 'failed delivery'
FAIL_SEND=0; metrics ok "$G0"; expect 9 'retry delivers'
metrics ok "$G0"; expect 9 'no duplicate after retry'
echo 'PASS: failed Discord delivery keeps baseline; retried once'

if grep -q 'secret' "$NOTICES"; then echo 'FAIL: GPU uuid leaked'; exit 1; fi
echo 'PASS: GPU uuids never sent'

before=$(cat "$WATCHMAN_STATE_DIR/gpu-ids.json")
WATCHMAN_METRICS_MODE=sidecar METRICS_MODE=sidecar; metrics ok ""; METRICS_MODE=local
[[ $(cat "$WATCHMAN_STATE_DIR/gpu-ids.json") == "$before" ]] || { echo 'FAIL: sidecar mode changed baseline'; exit 1; }
expect 9 'sidecar mode'
echo '{"bad":1}' > "$WATCHMAN_STATE_DIR/gpu-ids.json"
if metrics ok "$G0,$G1" 2>/dev/null; then echo 'FAIL: invalid baseline accepted'; exit 1; fi
expect 9 'invalid baseline'
echo 'PASS: sidecar mode ignored; invalid baseline refused'
echo '9 GPU-change scenarios passed; send() intercepted locally.'
