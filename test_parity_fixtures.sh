#!/usr/bin/env bash
# Offline fixture-based parity reporting regression; never uses live Unraid files.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
printf 'mdState="STARTED"\n' > "$TMP/var.ini"
for scenario in unassigned healthy failed unknown; do
  case "$scenario" in
    unassigned) dev=''; status=DISK_NP_DSBL; expected='parity assignment: not assigned' ;;
    healthy) dev=FAKE_PARITY; status=DISK_OK; expected='parity assignment: assigned; status DISK_OK (parity protection not verified)' ;;
    failed) dev=FAKE_PARITY; status=DISK_DSBL; expected='parity assignment: assigned; status DISK_DSBL (parity protection not verified)' ;;
    unknown) dev=FAKE_PARITY; status=UNKNOWN; expected='parity assignment: assigned; status UNKNOWN (parity protection not verified)' ;;
  esac
  printf '["parity"]\nname="parity"\ndevice="%s"\nstatus="%s"\n["parity2"]\nname="parity2"\ndevice=""\nstatus="DISK_NP_DSBL"\n["disk1"]\nname="disk1"\ndevice="FAKE_DISK1"\nstatus="DISK_OK"\nfsStatus="Mounted"\n' "$dev" "$status" > "$TMP/disks.ini"
  WATCHMAN_STATE_DIR="$TMP/state-$scenario" \
  WATCHMAN_DISKS_INI="$TMP/disks.ini" WATCHMAN_VAR_INI="$TMP/var.ini" \
  WATCHMAN_SYSLOG="$TMP/nonexistent-syslog" WATCHMAN_METRICS_URL="http://127.0.0.1:9/metrics" \
  WATCHMAN_DISKS='[]' WATCHMAN_CONTAINERS='[]' \
  bash "$HERE/watchman_engine.sh" --report > "$TMP/out-$scenario"
  grep -Fqx "$expected" "$TMP/out-$scenario" || { echo "FAIL: $scenario"; cat "$TMP/out-$scenario"; exit 1; }
  grep -Fqx 'parity2 assignment: not assigned' "$TMP/out-$scenario"
  echo "PASS: $scenario"
done
echo '4 parity report fixtures passed; no notifications or disk operations performed.'
