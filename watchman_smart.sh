#!/usr/bin/env bash
# NAS Watchman SMART observation collector. Reads only; does not wake standby disks.
# Input: JSON object of parsed Unraid disks.ini sections. Output: sanitized JSON array.
set -euo pipefail
export LC_ALL=C
[[ $# -ge 1 && $# -le 2 && -r $1 ]] || { echo "Usage: $0 parsed-disks.json [selected-disk-json-array]" >&2; exit 2; }
source_json=$1
# The second argument comes from the validated engine configuration. Older
# one-argument diagnostic callers retain the original scan-all behavior.
selected=${2:-null}
jq -en --argjson selected "$selected" '$selected==null or ($selected|type)=="array" and all($selected[];type=="string")' >/dev/null 2>&1 || exit 2
tmp=$(mktemp -d /tmp/watchman-smart.XXXXXXXX) || exit 1
trap 'rm -rf -- "$tmp"' EXIT
: > "$tmp/samples"
command -v jq >/dev/null || exit 1
if ! command -v smartctl >/dev/null || ! command -v lsblk >/dev/null; then
  echo '[]'
  exit 0
fi
# Keep the full stable drive ID locally; it is never sent in Discord notices.
# JSON-lines avoids confusing unusual serial characters with shell field delimiters.
jq -cr --argjson selected "$selected" '
  to_entries[] | select(.value.type == "Parity" or .value.type == "Data" or .value.type == "Cache") |
  select($selected==null or .value.type=="Parity" or (.key|IN($selected[]))) |
  {name:.key,device:(.value.device // ""),id:(.value.id // "")}' "$source_json" |
while IFS= read -r disk; do
  slot=$(jq -r '.name' <<<"$disk")
  device=$(jq -r '.device' <<<"$disk")
  disk_id=$(jq -r '.id' <<<"$disk")
  [[ $slot =~ ^[A-Za-z0-9_.-]+$ ]] || continue
  # Never accept arbitrary paths or Unraid md partitions from filesystem metadata.
  [[ $device =~ ^sd[a-z]+$ || $device =~ ^nvme[0-9]+n[0-9]+$ ]] || continue
  path="/dev/$device"
  transport=$(lsblk -dn -o TRAN "$path" 2>/dev/null | tr -d '[:space:]') || transport=''
  case "$transport" in
    sata|sas|nvme) ;;
    *) continue ;; # USB, missing, unknown: do not interrogate
  esac
  rota=$(lsblk -dn -o ROTA "$path" 2>/dev/null | tr -d '[:space:]') || rota=''
  if [[ $transport == nvme ]]; then class=nvme
  elif [[ $rota == 0 ]]; then class=ssd
  else class=hdd
  fi
  : > "$tmp/read.json"
  # smartctl can return nonzero *with valid SMART data* (e.g. a failing drive).
  # -n standby suppresses reads that would spin up a sleeping disk.
  timeout 12 smartctl -n standby -a -j "$path" > "$tmp/read.json" 2>/dev/null || :
  if ! jq -e 'type=="object" and (.smartctl|type)=="object"' "$tmp/read.json" >/dev/null 2>&1; then
    echo '{}' > "$tmp/read.json"
  fi
  jq -cn --arg name "$slot" --arg class "$class" --arg id "$disk_id" --arg device "$device" --slurpfile obj "$tmp/read.json" '
    $obj[0] as $s |
    def raw($id): ([$s.ata_smart_attributes.table[]? | select(.id==$id) | (.raw.value | try tonumber catch null)] | first) // null;
    def nonneg($v): if ($v|type)=="number" and $v>=0 then $v else null end;
    def standby: ([$s.smartctl.messages[]?.string // empty] | join(" ") | ascii_downcase | test("standby|sleeping|low.power"));
    (if ($s.smart_status.passed|type)=="boolean" then $s.smart_status.passed else null end) as $health |
    ($s.temperature.current // null) as $temp |
    # Attribute-only responses are usable even when health and temperature are absent.
    # Never classify a sleeping disk as healthy, even if a device returns other fields.
    ([ $health, $temp, raw(197), raw(198), raw(187), raw(5), raw(199),
       $s.nvme_smart_health_information_log.critical_warning,
       $s.nvme_smart_health_information_log.media_errors ] | any(. != null)) as $has_reading |
    (if standby then "standby" elif $has_reading then "ok" else "unknown" end) as $status |
    {name:$name,id:$id,device:$device,class:$class,status:$status,
     smart_passed:(if ($health|type)=="boolean" then $health else null end),
     temperature_c:(if ($temp|type)=="number" and $temp>=-30 and $temp<=150 then $temp else null end),
     pending:nonneg(raw(197)),uncorrectable:nonneg(raw(198)),
     reported_uncorrectable:nonneg(raw(187)),reallocated:nonneg(raw(5)),
     crc:nonneg(raw(199)),
     nvme_critical_warning:nonneg($s.nvme_smart_health_information_log.critical_warning),
     nvme_media_errors:nonneg($s.nvme_smart_health_information_log.media_errors)}
    | if .status=="ok" then . else {name,id,device,class,status} end
  ' >> "$tmp/samples"
done
jq -s '.' "$tmp/samples"
