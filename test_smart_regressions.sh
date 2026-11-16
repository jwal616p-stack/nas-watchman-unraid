#!/usr/bin/env bash
# Regression tests for attribute-only SMART, drive identity, trend history, and temp escalation.
# Uses mocked commands and a private state directory; never contacts actual drives/Discord.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
export PATH="$T/bin:$PATH" SMART_CALLS="$T/calls" SMART_FIXTURE="$T/smart-input.json"
: > "$SMART_CALLS"
cat > "$T/bin/lsblk" <<'MOCK'
#!/usr/bin/env bash
for last in "$@"; do :; done
case "$*" in
  *TRAN*) case "$last" in /dev/sdb|/dev/sdc) echo sata ;; /dev/sda) echo usb ;; esac ;;
  *ROTA*) echo "${MOCK_ROTA:-1}" ;;
esac
MOCK
cat > "$T/bin/smartctl" <<'MOCK'
#!/usr/bin/env bash
[[ " $* " == *" -n standby "* ]] || exit 91
printf '%s\n' "$*" >> "$SMART_CALLS"
cat "$SMART_FIXTURE"
MOCK
chmod +x "$T/bin/lsblk" "$T/bin/smartctl"
write_disk() {
  jq -n --arg id "$1" --arg dev "$2" '{disk1:{type:"Data",id:$id,device:$dev}}' > "$WORK/disks"
}
write_smart() {
  jq -n --argjson temp "$1" --argjson pending "$2" --argjson unrecoverable "$3" --argjson realloc "$4" --argjson crc "$5" '
    {smartctl:{exit_status:0},smart_status:{passed:true},temperature:{current:$temp},
     ata_smart_attributes:{table:[
       {id:197,raw:{value:$pending}},{id:198,raw:{value:$unrecoverable}},
       {id:5,raw:{value:$realloc}},{id:199,raw:{value:$crc}}]}}' > "$SMART_FIXTURE"
}
export WATCHMAN_STATE_DIR="$T/state" WATCHMAN_SYSLOG="$T/none" WATCHMAN_DISKS_INI="$T/none" WATCHMAN_VAR_INI="$T/none"
export WATCHMAN_DISKS='["disk1"]' WATCHMAN_CONTAINERS='[]' WATCHMAN_SMART_ENABLED=1 WATCHMAN_SMART_INTERVAL=3600
source <(sed '/^collect || exit 1$/,$d' "$ROOT/watchman_engine.sh")
LOCAL_SMART="$ROOT/watchman_smart.sh"
MODE=--once
NOTICES="$T/notices"; : > "$NOTICES"
TREND_FAIL=0
send() {
  if [[ $TREND_FAIL == 1 && $1 == *'SMART trends'* ]]; then return 1; fi
  printf '%s\n' "$1" >> "$NOTICES"
}
scan() { echo '{}' > "$WORK/events"; : > "$WORK/report"; collect_smart && check_alerts && scan_smart_trends; }
refresh() { echo 0 > "$T/state/smart-snapshot-at"; }
write_disk 'DRIVE_A' sdb
# Failure regression: no overall health or temperature, but known severe errors.
cat > "$SMART_FIXTURE" <<'JSON'
{"smartctl":{"exit_status":0},"ata_smart_attributes":{"table":[{"id":197,"raw":{"value":12}},{"id":198,"raw":{"value":3}}]}}
JSON
scan
jq -e '.[0].status=="ok" and .[0].pending==12 and .[0].uncorrectable==3 and .[0].temperature_c==null' "$WORK/smart.json" >/dev/null
grep -Fq 'ALERT: disk1 SMART pending sectors: 12' "$NOTICES"
grep -Fq 'ALERT: disk1 SMART offline uncorrectable sectors: 3' "$NOTICES"
echo 'PASS: attribute-only SMART warnings survive unknown health/temperature'
# Replace while cache is unexpired: must probe new identity and not reuse old temp.
write_smart 63 0 0 4 7
refresh; scan
jq -e '.[0].temperature_c==63' "$WORK/smart.json" >/dev/null
before=$(wc -l < "$SMART_CALLS")
write_disk 'DRIVE_B' sdc
write_smart 29 0 0 4 7
scan
jq -e '.[0].id=="DRIVE_B" and .[0].device=="sdc" and .[0].temperature_c==29' "$WORK/smart.json" >/dev/null
[[ $(wc -l < "$SMART_CALLS") == $((before+1)) ]]
scan
[[ $(wc -l < "$SMART_CALLS") == $((before+1)) ]]
echo 'PASS: drive replacement invalidates hourly snapshot; unchanged identity stays cached'
# Pre-existing reallocated sectors on the newly observed drive get one alert.
[[ $(grep -c '^NAS Watchman - .*SMART trends' "$NOTICES" || true) == 2 ]]
grep -Fq 'reallocated sectors on initial observation' "$NOTICES"
write_smart 30 0 0 5 8
refresh; scan
[[ $(grep -c '^NAS Watchman - .*SMART trends' "$NOTICES") == 3 ]]
grep -Fq 'reallocated sectors increased: 4 -> 5' "$NOTICES"
grep -Fq 'CRC errors increased: 7 -> 8' "$NOTICES"
refresh; scan
[[ $(grep -c '^NAS Watchman - .*SMART trends' "$NOTICES") == 3 ]]
! grep -Fq 'RECOVERY: disk1 SMART reallocated' "$NOTICES"
echo 'PASS: reallocated and CRC increases generate one-shot notices, not recovery spam'
# Delivery failure must retain baseline so the increase is retried on next scan.
write_smart 31 0 0 6 9
refresh; TREND_FAIL=1
if scan; then echo 'FAIL: simulated trend notification delivery failure ignored' >&2; exit 1; fi
jq -e '.disk1.reallocated==5 and .disk1.crc==8' "$T/state/smart-trends.json" >/dev/null
TREND_FAIL=0
# Retry should consume the identity-checked hourly cache without probing again.
before=$(wc -l < "$SMART_CALLS")
scan
[[ $(wc -l < "$SMART_CALLS") == "$before" ]]
[[ $(grep -c '^NAS Watchman - .*SMART trends' "$NOTICES") == 4 ]]
jq -e '.disk1.reallocated==6 and .disk1.crc==9' "$T/state/smart-trends.json" >/dev/null
echo 'PASS: failed Discord delivery retries unchanged baseline on next scan'
# New disk in same slot must not compare historical counters against old disk.
write_disk 'DRIVE_C' sdb
write_smart 32 0 0 40 50
refresh; scan
[[ $(grep -c '^NAS Watchman - .*SMART trends' "$NOTICES") == 5 ]]
jq -e '.disk1.id=="DRIVE_C" and .disk1.reallocated==40' "$T/state/smart-trends.json" >/dev/null
grep -Fq 'SMART WARNING: disk1 has 40 reallocated sectors on initial observation' "$NOTICES"
echo 'PASS: drive replacement resets monotonic trend comparison'
# Missing health/temperature must not reset previously active error alerts.
cat > "$SMART_FIXTURE" <<'JSON'
{"smartctl":{"exit_status":2,"messages":[{"string":"Device is in STANDBY mode"}]}}
JSON
refresh; scan
jq -e '.[0].status=="standby"' "$WORK/smart.json" >/dev/null
! grep -Fq 'RECOVERY: disk1 SMART pending' "$NOTICES"
echo 'PASS: standby never fabricates zero counters or recovery'
# A single event key represents temperature warning OR critical; critical
# escalation is delivered once and recovery only once on actual cooling.
: > "$NOTICES"; echo '{}' > "$T/state/state.json"
write_smart 63 0 0 40 50
refresh
printf '%s\n' '{"disk_disk1_temp":{"bad":true,"message":"Unraid cached temperature high"}}' > "$WORK/events"
: > "$WORK/report"
collect_smart
jq -e '[keys[]|select(contains("temp"))] | length==1' "$WORK/events" >/dev/null
jq -e '.disk_disk1_temp.level==2 and .disk_disk1_temp.bad==true' "$WORK/events" >/dev/null
check_alerts
[[ $(grep -c 'disk1 SMART CRITICAL temperature' "$NOTICES") == 1 ]]
[[ $(grep -c 'temperature' "$NOTICES") == 1 ]]
write_smart 52 0 0 40 50
refresh; scan
grep -Fq 'DE-ESCALATION: disk1 SMART temperature 52 C' "$NOTICES"
write_smart 47 0 0 40 50
refresh; scan
grep -Fq 'RECOVERY: disk1 SMART temperature 47 C' "$NOTICES"
echo 'PASS: one temperature event per disk, escalation, de-escalation and recovery'
# Disk swap: a failed physical drive must NOT appear to recover merely because
# a healthy replacement now occupies disk1. Keep the old incident on disk.
: > "$NOTICES"
echo '{}' > "$T/state/state.json"
write_disk 'FAILED_OLD' sdb
write_smart 35 5 0 2 2
refresh; scan
grep -Fq 'ALERT: disk1 SMART pending sectors: 5' "$NOTICES"
write_disk 'HEALTHY_NEW' sdc
write_smart 35 0 0 0 0
scan
! grep -Fq 'RECOVERY: disk1 SMART pending' "$NOTICES"
! grep -Fq 'RECOVERY: disk1 SMART self-assessment' "$NOTICES"
jq -e '."smart_disk1_pending|FAILED_OLD".bad==true and ."smart_disk1_pending|FAILED_OLD".drive_id=="FAILED_OLD"' "$T/state/retired-smart-incidents.json" >/dev/null
jq -e '.smart_disk1_pending.bad==false and .smart_disk1_pending.drive_id=="HEALTHY_NEW"' "$T/state/state.json" >/dev/null
echo 'PASS: replaced disk never sends fake recoveries; old failing incident is archived'
# A *new* failing replacement needs a fresh alert even if the prior disk failed.
write_disk 'FAILED_REPLACEMENT' sdb
write_smart 35 9 0 0 0
scan
grep -Fq 'ALERT: disk1 SMART pending sectors: 9' "$NOTICES"
echo 'PASS: a newly failing physical disk emits an independent alert'
# A custom 45 C threshold must never be cleared by the SMART 50 C default.
: > "$NOTICES"
WATCHMAN_DISK_TEMP_LIMITS='{"disk1":45}'
write_disk 'CUSTOM_TEMP' sdc
write_smart 47 0 0 0 0
refresh; scan
jq -e '.disk_disk1_temp.bad==true and .disk_disk1_temp.level==1 and .disk_disk1_temp.drive_id=="CUSTOM_TEMP"' "$T/state/state.json" >/dev/null
! grep -Fq 'RECOVERY: disk1 SMART temperature' "$NOTICES"
grep -Fq 'warning threshold 45 C' "$NOTICES"
write_smart 44 0 0 0 0
refresh; scan
grep -Fq 'RECOVERY: disk1 SMART temperature 44 C' "$NOTICES"
echo 'PASS: custom 45 C warning overrides SMART default, recovery only on cooling'
# Overrides above class-critical must move critical higher (rather than
# announcing critical temperatures while still below the user's warning).
: > "$NOTICES"
WATCHMAN_DISK_TEMP_LIMITS='{"disk1":65}'
write_smart 63 0 0 0 0
refresh; scan
jq -e '.disk_disk1_temp.bad==false and .disk_disk1_temp.level==0' "$T/state/state.json" >/dev/null
write_smart 66 0 0 0 0
refresh; scan
jq -e '.disk_disk1_temp.bad==true and .disk_disk1_temp.level==1' "$T/state/state.json" >/dev/null
write_smart 76 0 0 0 0
refresh; scan
jq -e '.disk_disk1_temp.bad==true and .disk_disk1_temp.level==2' "$T/state/state.json" >/dev/null
grep -Fq 'ESCALATION: disk1 SMART CRITICAL temperature 76 C; threshold 75 C' "$NOTICES"
echo 'PASS: high custom warning threshold raises critical escalation appropriately'
WATCHMAN_DISK_TEMP_LIMITS='{}'
WATCHMAN_DISK_TEMP_DEFAULT=45
: > "$NOTICES"
write_disk 'GLOBAL_TEMP' sdb
write_smart 47 0 0 0 0
refresh; scan
jq -e '.disk_disk1_temp.bad==true and .disk_disk1_temp.level==1' "$T/state/state.json" >/dev/null
WATCHMAN_DISK_TEMP_DEFAULT=55
echo 'PASS: explicitly changed global Unraid temperature threshold is respected'
# R1: a corrupt hourly-cache timestamp must not stop independent disk alerts.
: > "$NOTICES"
echo '{}' > "$T/state/state.json"
write_disk 'R1_CACHE' sdb
write_smart 33 0 0 0 0
refresh; scan
echo 'broken-timestamp' > "$T/state/smart-snapshot-at"
echo '{"array_fault":{"bad":true,"message":"md: disk1 write error"}}' > "$WORK/events"
: > "$WORK/report"
collect_smart && check_alerts
grep -Fq 'ALERT: md: disk1 write error' "$NOTICES"
grep -Fq 'broken-timestamp' "$T/state/smart-snapshot-at.invalid"
echo 'PASS: corrupt SMART cache cannot suppress independent critical disk alarms'

# Reconcile real Unraid temperature and SMART class/temperature into one key.
# Mock disk readings are already parsed Unraid metadata, no real disk access.
write_disk_temp() {
  jq -n --arg id "$1" --arg temp "$2" \
    '{disk1:{type:"Data",id:$id,device:"sdb",temp:$temp,status:"DISK_OK",fsStatus:"Mounted",numErrors:"0"}}' > "$WORK/disks"
}
reconciled_scan() {
  echo '{}' > "$WORK/events"; : > "$WORK/report"
  collect_smart && reconcile_temps && check_alerts
}
: > "$NOTICES"
echo '{}' > "$T/state/state.json"
WATCHMAN_DISK_TEMP_LIMITS='{}'; WATCHMAN_DISK_TEMP_DEFAULT=55
DISK_TEMP_GLOBAL_EXPLICIT=0
write_disk_temp 'R2_TEMP' 40
write_smart 40 0 0 0 0
refresh; reconciled_scan
before=$(wc -l < "$SMART_CALLS")
write_disk_temp 'R2_TEMP' 75
reconciled_scan
[[ $(wc -l < "$SMART_CALLS") == "$before" ]] # cached SMART reading, no reprobe
jq -e '.disk_disk1_temp.bad==true and .disk_disk1_temp.level==2 and (.disk_disk1_temp.message|contains("75 C (Unraid)"))' "$T/state/state.json" >/dev/null
grep -Fq 'ALERT: disk1 CRITICAL temperature 75 C (Unraid)' "$NOTICES"
echo 'PASS: live 75 C Unraid overheat cannot be hidden by cached SMART 40 C'
# Missing SMART must not shift to the legacy 55 C threshold and clear 52 C.
write_disk_temp 'R2_TEMP' 52
reconciled_scan
jq -e '.disk_disk1_temp.bad==true and .disk_disk1_temp.level==1' "$T/state/state.json" >/dev/null
cat > "$T/failing-smart.sh" <<'MOCK'
#!/bin/bash
exit 44
MOCK
fail_smartsave=$LOCAL_SMART
LOCAL_SMART="$T/failing-smart.sh"
refresh; reconciled_scan
jq -e '.disk_disk1_temp.bad==true and .disk_disk1_temp.level==1' "$T/state/state.json" >/dev/null
! grep -Fq 'RECOVERY: disk1' "$NOTICES"
LOCAL_SMART=$fail_smartsave
write_disk_temp 'R2_TEMP' 49
refresh; reconciled_scan
grep -Fq 'RECOVERY: disk1 temperature 49 C' "$NOTICES"
echo 'PASS: SMART dropout retains HDD 50 C warning; actual cooling recovers once'
# Unknown (standby) readings with no live temperature must NOT clear an alert.
write_disk_temp 'STANDBY_TEMP' 52
write_smart 52 0 0 0 0
refresh; reconciled_scan
cat > "$SMART_FIXTURE" <<'JSON'
{"smartctl":{"exit_status":2,"messages":[{"string":"Device is in STANDBY mode"}]}}
JSON
write_disk_temp 'STANDBY_TEMP' '*'
refresh; reconciled_scan
jq -e '.disk_disk1_temp.bad==true and .disk_disk1_temp.drive_id=="STANDBY_TEMP"' "$T/state/state.json" >/dev/null
! grep -Fq 'RECOVERY: disk1 temperature 52 C' "$NOTICES"
echo 'PASS: sleeping disk never wakes or fabricates a cool temperature'
# R6: explicit disk_temp_default=55 wins even for SSDs (SMART SSD default=60).
: > "$NOTICES"; echo '{}' > "$T/state/state.json"
export MOCK_ROTA=0
WATCHMAN_DISK_TEMP_DEFAULT=55
DISK_TEMP_GLOBAL_EXPLICIT=1
write_disk_temp 'R6_SSD' 57
write_smart 57 0 0 0 0
refresh; reconciled_scan
jq -e '.disk_disk1_temp.bad==true and .disk_disk1_temp.level==1 and (.disk_disk1_temp.message|contains("55 C"))' "$T/state/state.json" >/dev/null
grep -Fq 'ALERT: disk1 temperature 57 C (Unraid)' "$NOTICES"
unset MOCK_ROTA
DISK_TEMP_GLOBAL_EXPLICIT=0
echo 'PASS: explicitly configured 55 C threshold applies to SSDs'
# A same-ID reallocated-sector decrease is anomalous, not a recovery.
write_disk 'R8_ANOMALY' sdb
write_smart 30 0 0 50 0
refresh; scan
write_smart 30 0 0 2 0
refresh; scan
grep -Fq 'reallocated sector counter decreased: 50 -> 2' "$NOTICES"
echo 'PASS: existing bad sectors and counter decreases get independent notices'
# No first-run class: USB SSD or offline SMART should not inherit HDD 50/60.
: > "$NOTICES"; echo '{}' > "$T/state/state.json"
rm -f "$T/state/smart-snapshot.json" "$T/state/smart-snapshot-at" "$T/state/smart-snapshot-identity.json"
write_disk_temp 'UNKNOWN_NVME' 65
LOCAL_SMART="$T/failing-smart.sh"
reconciled_scan
jq -e '.disk_disk1_temp.bad==true and .disk_disk1_temp.level==1 and (.disk_disk1_temp.message|contains("warning threshold 55 C"))' "$T/state/state.json" >/dev/null
! grep -Fq 'CRITICAL temperature 65 C' "$NOTICES"
echo 'PASS: unknown drive class uses fallback warning, never invented HDD critical'
# If a previously classified HDD is hot but its snapshot is lost, preserve
# the existing alert until a comparable, identity-matched sample returns.
LOCAL_SMART=$fail_smartsave
write_disk_temp 'LOSS_OF_CLASS' 52
write_smart 52 0 0 0 0
refresh; reconciled_scan
jq -e '.disk_disk1_temp.bad==true and .disk_disk1_temp.level==1' "$T/state/state.json" >/dev/null
: > "$NOTICES"
printf '%s\n' '{damaged' > "$T/state/smart-snapshot.json"
LOCAL_SMART="$T/failing-smart.sh"
reconciled_scan
jq -e '.disk_disk1_temp.bad==true and .disk_disk1_temp.level==1' "$T/state/state.json" >/dev/null
[[ ! -s "$NOTICES" ]]
LOCAL_SMART=$fail_smartsave
write_disk_temp 'LOSS_OF_CLASS' 47
write_smart 47 0 0 0 0
refresh; reconciled_scan
grep -Fq 'RECOVERY: disk1 temperature 47 C' "$NOTICES"
echo 'PASS: losing SMART class cannot falsely clear active alert; measured cooling can'
echo '20 SMART regression scenarios passed.'
