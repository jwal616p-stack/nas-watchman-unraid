#!/usr/bin/env bash
# Fixture-only SMART regression, no access to real disks or network.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
export PATH="$T/bin:$PATH" SMART_CALLS="$T/calls" SMART_CASE=hot
: > "$SMART_CALLS"
cat > "$T/bin/lsblk" <<'MOCK'
#!/usr/bin/env bash
for last in "$@"; do :; done
if [[ $* == *TRAN* ]]; then
  case "$last" in /dev/sdb|/dev/sdf) echo sata;; /dev/nvme0n1) echo nvme;; /dev/sda) echo usb;; esac
else
  case "$last" in /dev/sdb|/dev/sdf|/dev/sda) echo 1;; /dev/nvme0n1) echo 0;; esac
fi
MOCK
cat > "$T/bin/smartctl" <<'MOCK'
#!/usr/bin/env bash
[[ " $* " == *" -n standby "* ]] || exit 90
printf '%s\n' "$*" >> "$SMART_CALLS"
for last in "$@"; do :; done
case "$last" in
 /dev/sdf) echo '{"smartctl":{"exit_status":2,"messages":[{"string":"Device is in STANDBY mode"}]}}'; exit 2 ;;
 /dev/sdb)
   if [[ $SMART_CASE == standby ]]; then
     echo '{"smartctl":{"exit_status":2,"messages":[{"string":"Device is in STANDBY mode"}]}}'; exit 2
   elif [[ $SMART_CASE == cool ]]; then
     echo '{"smartctl":{"exit_status":0},"smart_status":{"passed":true},"temperature":{"current":37},"ata_smart_attributes":{"table":[{"id":197,"raw":{"value":0}}]}}'
   else
     echo '{"smartctl":{"exit_status":0},"smart_status":{"passed":true},"temperature":{"current":63},"ata_smart_attributes":{"table":[{"id":197,"raw":{"value":2}}]}}'
   fi ;;
 /dev/nvme0n1)
   if [[ $SMART_CASE == standby ]]; then
     echo '{"smartctl":{"exit_status":2,"messages":[{"string":"Device is in STANDBY mode"}]}}'; exit 2
   elif [[ $SMART_CASE == cool ]]; then
     echo '{"smartctl":{"exit_status":0},"smart_status":{"passed":true},"temperature":{"current":39},"nvme_smart_health_information_log":{"critical_warning":0,"media_errors":0}}'
   else
     echo '{"smartctl":{"exit_status":8},"smart_status":{"passed":false},"temperature":{"current":76},"nvme_smart_health_information_log":{"critical_warning":1,"media_errors":3}}'; exit 8
   fi ;;
 *) exit 91 ;;
esac
MOCK
chmod +x "$T/bin/lsblk" "$T/bin/smartctl"
cat > "$T/disks.json" <<'JSON'
{"disk1":{"type":"Data","device":"sdb","id":"HDD_A"},"parity":{"type":"Parity","device":"sdf","id":"HDD_P"},"storage":{"type":"Cache","device":"nvme0n1","id":"NVME_A"},"flash":{"type":"Flash","device":"sda","id":"FLASH_A"},"bad":{"type":"Data","device":"../../bad"}}
JSON
bash "$ROOT/watchman_smart.sh" "$T/disks.json" > "$T/snapshot.json"
jq -e 'length==3 and ([.[]|select(.name=="disk1" and .temperature_c==63 and .pending==2)]|length)==1 and ([.[]|select(.name=="parity" and .status=="standby")]|length)==1 and ([.[]|select(.name=="storage" and .smart_passed==false)]|length)==1' "$T/snapshot.json" >/dev/null
! grep -q '/dev/sda' "$SMART_CALLS"
echo 'PASS: safe transport selection, sleeping-drive handling, nonzero SMART exit codes'
export WATCHMAN_STATE_DIR="$T/state" WATCHMAN_SYSLOG="$T/none" WATCHMAN_DISKS_INI="$T/none" WATCHMAN_VAR_INI="$T/none"
export WATCHMAN_DISKS='["disk1","storage"]' WATCHMAN_CONTAINERS='[]' WATCHMAN_SMART_ENABLED=1 WATCHMAN_SMART_INTERVAL=3600
source <(sed '/^collect || exit 1$/,$d' "$ROOT/watchman_engine.sh")
LOCAL_SMART="$ROOT/watchman_smart.sh"
MODE=--once
cp "$T/disks.json" "$WORK/disks"
NOTICES="$T/notices"; : > "$NOTICES"
send() { printf '%s\n' "$1" >> "$NOTICES"; }
scan() { echo '{}' > "$WORK/events"; : > "$WORK/report"; collect_smart; check_alerts; }
scan
grep -Fq 'disk1 SMART CRITICAL temperature 63 C' "$NOTICES"
grep -Fq 'disk1 SMART pending sectors: 2' "$NOTICES"
grep -Fq 'storage SMART self-assessment: FAILED' "$NOTICES"
[[ $(grep -c '^NAS Watchman - ' "$NOTICES") == 1 ]]
[[ $(wc -l < "$SMART_CALLS") == 6 ]]
scan
[[ $(grep -c '^NAS Watchman - ' "$NOTICES") == 1 ]]
[[ $(wc -l < "$SMART_CALLS") == 6 ]]
echo 'PASS: health and high-temp alerts, plus hourly SMART cache without repeat probes'
SMART_CASE=standby
echo 0 > "$T/state/smart-snapshot-at"
scan
[[ $(grep -c '^NAS Watchman - ' "$NOTICES") == 1 ]] || { echo 'FAIL: sleeping disk cleared alarm' >&2; exit 1; }
echo 'PASS: sleeping disks never generate false recoveries'
SMART_CASE=cool
echo 0 > "$T/state/smart-snapshot-at"
scan
[[ $(grep -c '^NAS Watchman - ' "$NOTICES") == 2 ]]
grep -Fq 'RECOVERY: disk1 SMART' "$NOTICES"
echo 'PASS: cooled drive and restored SMART health send recovery once'
# Opted-out pool disk is not probed, but parity remains in scope.
: > "$SMART_CALLS"
WATCHMAN_DISKS='["disk1"]'
echo 0 > "$T/state/smart-snapshot-at"
scan
jq -e 'length==2 and ([.[]|.name]|sort)==["disk1","parity"]' "$WORK/smart.json" >/dev/null
! grep -Fq '/dev/nvme0n1' "$SMART_CALLS"
[[ $(wc -l < "$SMART_CALLS") == 2 ]]
echo 'PASS: opted-out pool devices not probed; parity always observed'
echo '5 SMART safety and alert scenarios passed.'
