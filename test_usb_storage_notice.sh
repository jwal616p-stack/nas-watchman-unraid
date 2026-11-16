#!/usr/bin/env bash
# USB fault classification, cursor, restart and delivery regression. Fixture syslog only.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export WATCHMAN_STATE_DIR="$T/state" WATCHMAN_SYSLOG="$T/syslog"
export WATCHMAN_BOOT_ID_FILE="$T/boot_id" WATCHMAN_WEBHOOK_FILE="$T/no-webhook"
export WATCHMAN_DISKS_INI="$T/none" WATCHMAN_VAR_INI="$T/none"
export WATCHMAN_CONTAINERS='[]' WATCHMAN_DISKS='[]' NOTICES="$T/notices"
mkdir -p "$T/state"
: > "$NOTICES"
printf 'test-boot\n' > "$T/boot_id"
# Import only worker functions: never collect, contact Discord, or access live disks.
sed '/^collect || exit 1$/,$d' "$ROOT/watchman_engine.sh" > "$T/defs.sh"
scan() {
  bash -c 'f=$1; set --; source "$f"; send() { [[ $(printenv FAIL_SEND || :) == 1 ]] && return 1; printf "%s\n" "$1" >> "$NOTICES"; }; scan_logs' _ "$T/defs.sh"
}
assert_count() {
  local found
  found=$(grep -c '^NAS Watchman - new system-log events' "$NOTICES" || :)
  [[ $found == "$1" ]] || { echo "expected $1 alerts; got $found"; cat "$NOTICES"; exit 1; }
}
has() { grep -Fq -- "$1" "$NOTICES" || { echo "missing $1"; cat "$NOTICES"; exit 1; }; }

echo 'Nov 14 17:00 JohnsVault kernel: normal startup' > "$T/syslog"
scan; assert_count 0
cat >> "$T/syslog" <<'LOG'
Nov 14 17:38:36 JohnsVault kernel: sd 10:0:0:1: [sdh] tag#9 uas_eh_abort_handler 0 uas-tag 7 inflight: CMD IN
Nov 14 17:39:06 JohnsVault kernel: sd 10:0:0:1: [sdh] tag#3 uas_eh_abort_handler 0 uas-tag 3 inflight: CMD IN
Nov 14 17:41:29 JohnsVault kernel: usb 4-1: USB disconnect, device number 3
Nov 14 17:41:29 JohnsVault kernel: sd 10:0:0:0: Device offlined - not ready after error recovery
Nov 14 17:41:51 JohnsVault kernel: XFS (md1p1): log I/O error -5
Nov 14 17:41:51 JohnsVault kernel: md: disk1 write error, sector=976887864
Nov 14 17:41:51 JohnsVault kernel: md: disk0 write error, sector=976887864
LOG
scan; assert_count 1
has 'USB STORAGE WARNING: 2 UAS abort/reset/recovery event(s).'
has 'USB STORAGE CRITICAL: 1 storage-device-offline event(s).'
has 'USB TRANSPORT NOTICE: 1 reset/disconnect event(s)'
has 'ARRAY WRITE ERROR: 2 Unraid md disk write-error event(s).'
has 'STORAGE ERROR: 1 matching I/O/filesystem/NVMe log entries.'
scan; scan; assert_count 1
echo 'PASS: critical JMicron incidents counted without replay across restarts'

cat >> "$T/syslog" <<'LOG'
Nov 14 17:43:00 JohnsVault kernel: usb 4-1: reset SuperSpeed USB device number 3 using xhci_hcd
Nov 14 17:43:01 JohnsVault kernel: usb 2-1: reset high-speed USB device number 5 using xhci_hcd
LOG
FAIL_SEND=1 scan || :
FAIL_SEND=1 scan || :
assert_count 1
scan; assert_count 2
has 'USB TRANSPORT NOTICE: 2 reset/disconnect event(s)'
scan; assert_count 2
echo 'PASS: failed delivery retains events; successful delivery advances cursor'

echo 'Nov 14 17:45:00 JohnsVault kernel: usb 4-1: new SuperSpeed USB device' >> "$T/syslog"
scan; assert_count 2
echo 'PASS: routine USB device announcements do not alert'

echo '4 USB fault regression scenarios passed; no real devices or Discord accessed.'
