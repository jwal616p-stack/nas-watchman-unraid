#!/usr/bin/env bash
# Isolated alert-state lifecycle regression: no Discord, no NAS disk operations.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export WATCHMAN_STATE_DIR
WATCHMAN_STATE_DIR=$(mktemp -d)
trap 'rm -rf "$WATCHMAN_STATE_DIR"' EXIT
export WATCHMAN_WEBHOOK_FILE="$WATCHMAN_STATE_DIR/nonexistent-webhook"
export WATCHMAN_SYSLOG="$WATCHMAN_STATE_DIR/nonexistent-syslog"
export WATCHMAN_DISKS_INI="$WATCHMAN_STATE_DIR/nonexistent-disks"
export WATCHMAN_VAR_INI="$WATCHMAN_STATE_DIR/nonexistent-var"
export WATCHMAN_CONTAINERS='[]' WATCHMAN_DISKS='[]'
# Load only definitions; do not run collect, mode dispatch, or network.
source <(sed '/^collect || exit 1$/,$d' "$ROOT/watchman_engine.sh")
trap 'rm -rf "$WORK" "$WATCHMAN_STATE_DIR"' EXIT
NOTICES="$WATCHMAN_STATE_DIR/notices"
: > "$NOTICES"
send() { printf '%s\n' "$1" >> "$NOTICES"; }
emit() {
  local status=$1
  case "$status" in
    healthy) printf '%s\n' '{"parity_parity":{"bad":false,"message":"parity: assigned; status DISK_OK (protection unverified)"}}' > "$WORK/events";;
    failed) printf '%s\n' '{"parity_parity":{"bad":true,"message":"parity: assigned; status DISK_DSBL (protection unverified)"}}' > "$WORK/events";;
    unknown) printf '%s\n' '{"parity_parity":{"bad":true,"message":"parity: assigned; status UNKNOWN (protection unverified)"}}' > "$WORK/events";;
    missing) printf '%s\n' '{}' > "$WORK/events";;
  esac
  check_alerts
}
assert_count() {
  local expected=$1 actual
  actual=$(grep -c "^NAS Watchman -" "$NOTICES" || true)
  [[ "$actual" -eq "$expected" ]] || { echo "FAIL: expected $expected notices, got $actual"; cat "$NOTICES"; exit 1; }
}
emit healthy; assert_count 0
emit failed; assert_count 1
grep -q 'ALERT: parity: assigned; status DISK_DSBL' "$NOTICES"
emit failed; emit failed; assert_count 1
emit healthy; assert_count 2
grep -q 'RECOVERY: parity: assigned; status DISK_OK' "$NOTICES"
emit healthy; assert_count 2
echo 'PASS: healthy -> failed -> failed -> healthy, single alert and recovery'
rm -f "$WATCHMAN_STATE_DIR/state.json"; : > "$NOTICES"
emit healthy; emit unknown; assert_count 1
grep -q 'ALERT: parity: assigned; status UNKNOWN' "$NOTICES"
emit unknown; assert_count 1
emit missing; assert_count 1
emit healthy; assert_count 2
grep -q 'RECOVERY: parity: assigned; status DISK_OK' "$NOTICES"
echo 'PASS: healthy -> unknown -> missing -> healthy, no false healthy during unknown/missing'
echo '2 alert lifecycle scenarios passed; send() intercepted locally.'
