#!/usr/bin/env bash
# Offline drive-identity change regression: fixtures only, no Discord, no NAS disk operations.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export WATCHMAN_STATE_DIR
WATCHMAN_STATE_DIR=$(mktemp -d)
trap 'rm -rf "$WATCHMAN_STATE_DIR"' EXIT
export WATCHMAN_WEBHOOK_FILE="$WATCHMAN_STATE_DIR/nonexistent-webhook"
export WATCHMAN_SYSLOG="$WATCHMAN_STATE_DIR/nonexistent-syslog"
export WATCHMAN_DISKS_INI="$WATCHMAN_STATE_DIR/disks.ini"
export WATCHMAN_VAR_INI="$WATCHMAN_STATE_DIR/var.ini"
export WATCHMAN_CONTAINERS='[]' WATCHMAN_DISKS='["disk1","disk2","disk3","Mediapool"]'
printf 'mdState="STARTED"\n' > "$WATCHMAN_VAR_INI"
# Load only definitions; do not run collect, mode dispatch, or network.
source <(sed '/^collect || exit 1$/,$d' "$ROOT/watchman_engine.sh")
trap 'rm -rf "$WORK" "$WATCHMAN_STATE_DIR"' EXIT
NOTICES="$WATCHMAN_STATE_DIR/notices"
: > "$NOTICES"
FAIL_SEND=0
send() { (( FAIL_SEND == 0 )) || return 1; printf '%s\n' "$1" >> "$NOTICES"; }
slot() { printf '["%s"]\nname="%s"\ntype="%s"\ndevice="%s"\nid="%s"\nstatus="DISK_OK"\nfsStatus="Mounted"\n' "$1" "$1" "$2" "${4:-sdx}" "$3"; }
P=WDC_WD20EFRX-68EUZN0_WD-PAR0000001
D1=WDC_WD20EFRX-68EUZN0_WD-AAAA000011
D2=WDC_WD20EFRX-68EUZN0_WD-BBBB000022
D3=WDC_WD20EFRX-68EUZN0_WD-CCCC000033
NEW=WDC_WD20EFRX-68EUZN0_WD-NEWW000099
M1=Samsung_SSD_970_EVO_Plus_1TB_S4EWNX0001
M2=Samsung_SSD_970_EVO_Plus_1TB_S4EWNX0002
FL=SanDisk_Cruzer_Fit_4C53000123
layout() { { slot parity Parity "$P"; slot disk1 Data "$1"; slot disk2 Data "$2"; slot disk3 Data "$3"; slot Mediapool Cache "$M1"; [[ -z ${4:-} ]] || slot Mediapool2 Cache "$4"; slot flash Flash "$FL"; } > "$WATCHMAN_DISKS_INI"; }
pass() { echo '{}' > "$WORK/events"; : > "$WORK/report"; collect_disks; scan_disk_changes; }
count() { grep -c '^NAS Watchman - .* drive changes$' "$NOTICES" || true; }
expect() { local n; n=$(count); [[ $n -eq $1 ]] || { echo "FAIL ($2): expected $1 notices, got $n"; cat "$NOTICES"; exit 1; }; }
has() { grep -Fq -- "$1" "$NOTICES" || { echo "FAIL: missing: $1"; cat "$NOTICES"; exit 1; }; }

layout "$D1" "$D2" "$D3"; pass; expect 0 'first run baseline'
[[ -f $WATCHMAN_STATE_DIR/disk-ids.json ]] || { echo 'FAIL: baseline not written'; exit 1; }
pass; expect 0 'unchanged'
echo 'PASS: first run records baseline silently; unchanged layout is quiet'

layout "$D1" "$NEW" "$D3"; pass; expect 1 'replacement'
has 'DISK CHANGE: disk2 [Data] drive changed from WDC WD20EFRX-68EUZN0 (serial ending 0022) to WDC WD20EFRX-68EUZN0 (serial ending 0099). Confirm this was intentional.'
if grep -Fq 'NEWW000099' "$NOTICES"; then echo 'FAIL: full serial leaked'; exit 1; fi
pass; expect 1 'no repeat after delivery'
echo 'PASS: replacement notified once, serial masked to last 4'

layout "$D1" "$D3" "$NEW"; pass; expect 2 'move'
has 'DISK CHANGE: disk2 [Data] drive changed from WDC WD20EFRX-68EUZN0 (serial ending 0099) to WDC WD20EFRX-68EUZN0 (serial ending 0033) (previously in disk3).'
has 'DISK CHANGE: disk3 [Data] drive changed from WDC WD20EFRX-68EUZN0 (serial ending 0033) to WDC WD20EFRX-68EUZN0 (serial ending 0099) (previously in disk2).'
echo 'PASS: swapped slots reported with previous location'

layout "$D1" "$D3" "$NEW" "$M2"; pass; expect 3 'pool member added'
has 'DISK ADDED: Mediapool2 [Cache] now has Samsung SSD 970 EVO Plus 1TB (serial ending 0002). Not monitored yet; rerun wizard discovery to include it.'
echo 'PASS: new unmonitored pool device flagged for discovery'

layout "$D1" "$D3" ""; pass; expect 4 'removal'
has 'DISK REMOVED: disk3 [Data] no longer reports WDC WD20EFRX-68EUZN0 (serial ending 0099).'
has 'DISK REMOVED: Mediapool2 [Cache] no longer reports'
echo 'PASS: removals reported'

layout "$D1" "$NEW" "$D2"; FAIL_SEND=1; pass || true; expect 4 'failed delivery'
FAIL_SEND=0; pass; expect 5 'retry after failed delivery'
has 'DISK ADDED: disk3 [Data] now has WDC WD20EFRX-68EUZN0 (serial ending 0022).'
has 'DISK CHANGE: disk2 [Data] drive changed from WDC WD20EFRX-68EUZN0 (serial ending 0033) to WDC WD20EFRX-68EUZN0 (serial ending 0099).'
pass; expect 5 'no duplicate after retry'
echo 'PASS: failed Discord delivery keeps baseline; retried once, no duplicate'

before=$(cat "$WATCHMAN_STATE_DIR/disk-ids.json")
rm -f "$WATCHMAN_DISKS_INI"; pass; expect 5 'unreadable disks.ini'
printf '["disk1"]\nname="disk1"\ndevice="sdc"\n' > "$WATCHMAN_DISKS_INI"; pass; expect 5 'id-less disks.ini'
[[ $(cat "$WATCHMAN_STATE_DIR/disk-ids.json") == "$before" ]] || { echo 'FAIL: baseline changed on missing data'; exit 1; }
echo 'PASS: unreadable or id-less disk data never reported as mass removal'

before=$(cat "$WATCHMAN_STATE_DIR/disk-ids.json")
printf 'mdState="STOPPED"\n' > "$WATCHMAN_VAR_INI"
layout "$D1" "" "$D2"; pass; expect 5 'stopped, slot reads blank'
layout "$D2" "$NEW" "$D1"; pass; expect 5 'stopped, drives swapped'
[[ $(cat "$WATCHMAN_STATE_DIR/disk-ids.json") == "$before" ]] || { echo 'FAIL: baseline changed while stopped'; exit 1; }
printf 'mdState="STARTED"\n' > "$WATCHMAN_VAR_INI"; pass; expect 6 'swap reported on start'
has 'DISK CHANGE: disk1 [Data] drive changed from WDC WD20EFRX-68EUZN0 (serial ending 0011) to WDC WD20EFRX-68EUZN0 (serial ending 0022) (previously in disk3).'
echo 'PASS: array stopped is quiet; swap made while stopped reported once on start'

FL=SanDisk_3.2Gen1_04019876abcd-0:0; layout "$D2" "$NEW" "$D1"; pass; expect 7 'flash replaced'
has 'DISK CHANGE: flash [Flash] drive changed from SanDisk Cruzer Fit (serial ending 0123) to SanDisk 3.2Gen1 (serial ending abcd).'
echo 'PASS: flash replacement reported; USB LUN suffix stripped'

echo '{"broken":1}' > "$WATCHMAN_STATE_DIR/disk-ids.json"; layout "$D1" "$NEW" "$D2"
if pass 2>/dev/null; then echo 'FAIL: invalid baseline accepted'; exit 1; fi
expect 7 'invalid baseline'
echo 'PASS: invalid baseline refused, nothing sent'
echo '10 drive-change scenarios passed; send() intercepted locally.'
