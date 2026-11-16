#!/bin/bash
# NAS Watchman 0.4.3 development preview -- host Bash worker for the existing telemetry sidecar.
# --report: local readings; --send-report: Discord readings; --ai: local AI summary
# --once: one alert check; --watch: checks every minute and a report every 24h.
# Cached Unraid disk status and selected new syslog events; no SMART tests or repairs.
set -uo pipefail
umask 077
export LC_ALL=C
MODE=${1:---report}
case "$MODE" in --report|--send-report|--ai|--once|--watch|--test-notify) ;; *) echo 'Use --report, --send-report, --ai, --once, --watch, or --test-notify'; exit 2;; esac
BASE=${WATCHMAN_STATE_DIR:-/mnt/user/appdata/watchman}
WEBHOOK_FILE=${WATCHMAN_WEBHOOK_FILE:-/boot/config/plugins/watchman/config/discord-webhook}
METRICS_URL=${WATCHMAN_METRICS_URL:-http://127.0.0.1:8001/metrics}
METRICS_MODE=${WATCHMAN_METRICS_MODE:-local}
LOCAL_COLLECTOR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/watchman_local_metrics.sh"
LOCAL_SMART="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/watchman_smart.sh"
SMART_ENABLED=${WATCHMAN_SMART_ENABLED:-0}
SMART_INTERVAL=${WATCHMAN_SMART_INTERVAL:-3600}
SMART_HDD_WARN=${WATCHMAN_SMART_HDD_WARN:-50}
SMART_HDD_CRIT=${WATCHMAN_SMART_HDD_CRIT:-60}
SMART_SSD_WARN=${WATCHMAN_SMART_SSD_WARN:-60}
SMART_SSD_CRIT=${WATCHMAN_SMART_SSD_CRIT:-70}
SMART_NVME_WARN=${WATCHMAN_SMART_NVME_WARN:-70}
SMART_NVME_CRIT=${WATCHMAN_SMART_NVME_CRIT:-80}
case "$METRICS_MODE" in sidecar|local) ;; *) echo 'WATCHMAN_METRICS_MODE must be sidecar or local' >&2; exit 2;; esac
OLLAMA_URL=${WATCHMAN_OLLAMA_URL:-http://127.0.0.1:11434/api/generate}
OLLAMA_MODEL=${WATCHMAN_OLLAMA_MODEL:-llama3.2:1b}
GPU_WARN=${WATCHMAN_GPU_WARN:-85}
RAM_WARN=${WATCHMAN_RAM_WARN:-90}
WATCHMAN_HOSTNAME=${WATCHMAN_HOSTNAME:-$(hostname)}
# JSON array of exact Docker container names to watch; [] disables named-container checks.
WATCHMAN_CONTAINERS=${WATCHMAN_CONTAINERS:-'[]'}
# Exact Unraid disk section names. Set to [] to disable per-disk checks.
WATCHMAN_DISKS=${WATCHMAN_DISKS:-'[]'}
# Distinguish a user-provided 55 C from the built-in default 55 C.
DISK_TEMP_GLOBAL_EXPLICIT=0
[[ ${WATCHMAN_DISK_TEMP_DEFAULT+x} ]] && DISK_TEMP_GLOBAL_EXPLICIT=1
DISK_TEMP_GLOBAL_EXPLICIT=${WATCHMAN_DISK_TEMP_DEFAULT_SET:-$DISK_TEMP_GLOBAL_EXPLICIT}
WATCHMAN_DISK_TEMP_DEFAULT=${WATCHMAN_DISK_TEMP_DEFAULT:-55}
[[ $DISK_TEMP_GLOBAL_EXPLICIT == 0 || $DISK_TEMP_GLOBAL_EXPLICIT == 1 ]] || { echo 'Invalid temperature explicit flag.' >&2; exit 2; }
WATCHMAN_DISK_TEMP_LIMITS=${WATCHMAN_DISK_TEMP_LIMITS:-'{}'}

if ! jq -en --argjson names "$WATCHMAN_DISKS" '$names | type=="array" and all(.[]; type=="string" and length>0) and (unique|length)==($names|length)' >/dev/null 2>&1; then
  echo 'WATCHMAN_DISKS must be a JSON array of unique nonempty strings.' >&2
  exit 2
fi
if ! jq -en --argjson names "$WATCHMAN_CONTAINERS" '$names | type=="array" and all(.[]; type=="string" and length>0)' >/dev/null 2>&1; then
  echo 'WATCHMAN_CONTAINERS must be a JSON array of nonempty strings.' >&2
  exit 2
fi
if ! jq -en --argjson limits "$WATCHMAN_DISK_TEMP_LIMITS" '$limits | type=="object" and all(to_entries[]; (.key|length)>0 and (.value|type)=="number" and (.value|floor)==.value and .value>=1 and .value<=120)' >/dev/null 2>&1; then
  echo 'Invalid WATCHMAN_DISK_TEMP_LIMITS: expected disk-name to integer Celsius (1..120).' >&2
  exit 2
fi
[[ $WATCHMAN_DISK_TEMP_DEFAULT =~ ^[0-9]{1,3}$ ]] && (( WATCHMAN_DISK_TEMP_DEFAULT>=1 && WATCHMAN_DISK_TEMP_DEFAULT<=120 )) || { echo 'Invalid WATCHMAN_DISK_TEMP_DEFAULT: expected 1..120.' >&2; exit 2; }
[[ $SMART_ENABLED == 0 || $SMART_ENABLED == 1 ]] || { echo 'WATCHMAN_SMART_ENABLED must be 0 or 1.' >&2; exit 2; }
[[ $SMART_INTERVAL =~ ^[0-9]{3,5}$ ]] && (( SMART_INTERVAL>=300 && SMART_INTERVAL<=86400 )) || { echo 'Invalid SMART interval (300..86400 seconds).' >&2; exit 2; }
for level in "$SMART_HDD_WARN" "$SMART_HDD_CRIT" "$SMART_SSD_WARN" "$SMART_SSD_CRIT" "$SMART_NVME_WARN" "$SMART_NVME_CRIT"; do
  [[ $level =~ ^[0-9]{1,3}$ ]] && (( level>=1 && level<=120 )) || { echo 'Invalid SMART temperature threshold (1..120 C).' >&2; exit 2; }
done
(( SMART_HDD_WARN < SMART_HDD_CRIT && SMART_SSD_WARN < SMART_SSD_CRIT && SMART_NVME_WARN < SMART_NVME_CRIT )) || { echo 'SMART warning must be below critical temperature.' >&2; exit 2; }
for number in "$GPU_WARN" "$RAM_WARN"; do
  [[ $number =~ ^[0-9]{1,3}$ ]] || { echo 'Thresholds must be whole numbers.'; exit 2; }
done
for tool in jq curl flock timeout dd stat awk base64; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool"; exit 1; }
done
# Only the alerting modes keep state. Report modes never create the state folder, so running a report
# while the array is stopped cannot create /mnt/user/appdata/... in RAM.
if [[ $MODE == --watch || $MODE == --once ]]; then
  mkdir -p "$BASE" || exit 1
  exec 9> "$BASE/worker.lock"
  # Short wait covers a previous engine that is still finishing; a real duplicate is still refused.
  flock -w 15 9 || { echo "Watchman worker already running."; exit 1; }
fi
WORK=$(mktemp -d /tmp/nas-watchman.XXXXXX) || exit 1
SLEEP_PID=''
trap 'rm -rf -- "$WORK"; [[ -z $SLEEP_PID ]] || kill "$SLEEP_PID" 2>/dev/null' EXIT
trap 'exit 0' TERM INT
send_chunk() {
  local url status
  IFS= read -r url < "$WEBHOOK_FILE" || { echo 'Cannot read webhook file.' >&2; return 1; }
  [[ $url =~ ^https://discord\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$ ]] || { echo 'Invalid webhook URL.' >&2; return 1; }
  jq -n --arg content "$1" '{content:($content[0:1900]),allowed_mentions:{parse:[]}}' > "$WORK/message"
  status=$(printf 'url = "%s?wait=true"\n' "$url" | curl --config - --silent \
    --connect-timeout 5 --max-time 25 -H 'Content-Type: application/json' \
    --data-binary @"$WORK/message" -o /dev/null -w '%{http_code}') || status=000
  [[ $status == 200 || $status == 204 ]] || { echo "Discord delivery failed (HTTP $status); state retained." >&2; return 1; }
}
send() {
  local chunk
  jq -nr --arg text "$1" '$text | [range(0; length; 1800) as $i | .[$i:$i+1800] | @base64] | .[]' > "$WORK/chunks" || return 1
  while IFS= read -r chunk; do
    send_chunk "$(printf '%s' "$chunk" | base64 -d)" || return 1
  done < "$WORK/chunks"
}
collect() {
  local metrics_ok=1
  if [[ "$METRICS_MODE" == local ]]; then
    bash "$LOCAL_COLLECTOR" > "$WORK/metrics" || metrics_ok=0
  else
    curl --silent --fail --connect-timeout 5 --max-time 20 "$METRICS_URL" -o "$WORK/metrics" || metrics_ok=0
  fi
  if (( metrics_ok )) &&
     jq -e 'type=="object" and (.memory.percent == null or (.memory.percent|type=="number" and .>=0 and .<=100)) and (.gpu|type=="object") and (.gpu.available|type=="boolean") and (if .gpu.available then (.gpu.temperature_c|type=="number" and .>=-50 and .<=200) else true end) and (.gpus == null or (.gpus|type=="array" and all(.[]; (.index|type)=="number" and (.available|type)=="boolean" and (if .available then (.temperature_c|type=="number" and .>=-50 and .<=200) else true end)))) and (.docker.available|type=="boolean") and (if .docker.available then (.docker.containers|type=="array" and all(.[]; (.name|type=="string") and (.status|type=="string"))) else true end)' "$WORK/metrics" >/dev/null 2>&1; then
    jq --argjson gw "$GPU_WARN" --argjson rw "$RAM_WARN" --argjson names "$WATCHMAN_CONTAINERS" '
      def check($bad;$msg): {bad:$bad,message:$msg};
      {telemetry:check(false;"Telemetry source reachable")}
       + (if (.memory.percent|type)=="number" then
           {ram:check(.memory.percent >= $rw;"RAM usage \(.memory.percent)% (warning >= \($rw)%)")}
          else {} end)
       # Per-card alerts when the collector lists every GPU; else the sidecar single-GPU contract.
       + (if (.gpus|type)=="array" and (.gpus|length)>0 then
           reduce .gpus[] as $g ({}; .["gpu_\($g.index)"] = (if $g.available then
             check($g.temperature_c >= $gw;"GPU \($g.index) (\($g.name // "unknown")) temperature \($g.temperature_c) C (warning >= \($gw) C)")
           else check(true;"GPU \($g.index) (\($g.name // "unknown")) reading unavailable") end))
          elif .gpu.available == true and (.gpu.temperature_c|type)=="number" then
           {gpu:check(.gpu.temperature_c >= $gw;"First GPU temperature \(.gpu.temperature_c) C (warning >= \($gw) C)")}
          else {} end)
       + (if .docker.available == true then
           {docker:check(false;"Docker telemetry available")}
          else {} end)
       + (if .docker.available == true and (.docker.containers|type)=="array" then
          .docker.containers as $cs | reduce $names[] as $n ({};
          .["container_"+$n]=check(([$cs[] | select(.name==$n and .status=="running")]|length)==0;"Container \($n): \(if ([$cs[]|select(.name==$n and .status=="running")]|length)>0 then "running" else "not reported running; may be intentionally stopped" end)"))
          else {} end)' "$WORK/metrics" > "$WORK/events" || return 1
    jq -r '"NAS Watchman - measured snapshot\nRAM: \(.memory.percent // "unknown")%\n\(if (.gpus|type)=="array" and (.gpus|length)>0 then (.gpus | map("GPU \(.index) (\(.name // "unknown")): " + (if .available then "\(.temperature_c) C; load \(.utilization_percent)%; VRAM \(.memory_used_mb) / \(.memory_total_mb) MiB" else "reading unavailable" end)) | join("\n")) else "First GPU: \(.gpu.temperature_c // "unknown") C; load \(.gpu.utilization_percent // "unknown")%; VRAM \(.gpu.memory_used_mb // "unknown") / \(.gpu.memory_total_mb // "unknown") MiB" end)\nDocker readings available: \(.docker.available // false)\nRunning containers reported: \(if .docker.available then (.docker.containers|length) else "unknown" end)\n\(if .disk.percent == null then "Telemetry filesystem usage: not collected (per-disk usage below)" else "Sidecar filesystem usage: \(.disk.percent)% (not verified as array usage)" end)\nNo overall health verdict."' "$WORK/metrics" > "$WORK/report"
  else
    printf '%s\n' '{"telemetry":{"bad":true,"message":"Telemetry API unavailable or invalid; other checks unknown"}}' > "$WORK/events"
    printf 'NAS Watchman: telemetry unavailable. Other checks unknown.\n' > "$WORK/report"
  fi
  collect_disks || return 1
  if ! collect_smart; then
    echo 'SMART: UNKNOWN (optional monitoring failure; other checks continue).' >> "$WORK/report"
  fi
  reconcile_temps || return 1
}
check_alerts() {
  local notice
  if [[ -f $BASE/state.json ]]; then
    jq -e 'type=="object" and all(.[]; (.bad|type)=="boolean")' "$BASE/state.json" >/dev/null 2>&1 || { echo 'Invalid state.json; refusing to discard alert history.' >&2; return 1; }
    cp "$BASE/state.json" "$WORK/old"
  else echo '{}' > "$WORK/old"; fi
  notice=$(jq -rn --slurpfile old "$WORK/old" --slurpfile now "$WORK/events" '
    $now[0] | to_entries | map(. as $e |
      ($old[0][$e.key] // {}) as $stored |
      # A new physical drive is not a recovery of its predecessor. Treat an
      # ID change as fresh state; a new failure is still reported as an alert.
      (if ($e.value.drive_id != null and $e.value.drive_id != "" and
           $stored.drive_id != $e.value.drive_id) then {} else $stored end) as $p |
      # Legacy warning events without levels are treated as level 1 for safe
      # escalation to SMART critical without duplicate warning notifications.
      ($p.level // (if $p.bad==true then 1 else 0 end)) as $prior_level |
      ($e.value.level // $prior_level) as $new_level |
      select(($e.value.bad and ($p.bad != true)) or
             ($e.value.bad == false and $p.bad == true) or
             ($e.value.bad == true and $p.bad == true and $e.value.level != null and $new_level!=$prior_level)) |
      (if .value.bad==false then "RECOVERY: "
       elif $p.bad==true and $new_level>$prior_level then "ESCALATION: "
       elif $p.bad==true and $new_level<$prior_level then "DE-ESCALATION: "
       else "ALERT: " end) + .value.message) | join("\n")') || return 1
  if [[ -n $notice ]]; then
    send "NAS Watchman - ${WATCHMAN_HOSTNAME}
$notice" || return 1
  fi
  # Preserve old active SMART incidents when their slot is occupied by a
  # different drive. This archive stays on the NAS and is never sent to Discord.
  # Only archive after notifications have been delivered successfully.
  if [[ -f $BASE/retired-smart-incidents.json ]]; then
    jq -e 'type=="object" and all(.[]; (.bad==true) and (.drive_id|type)=="string")' \
      "$BASE/retired-smart-incidents.json" >/dev/null 2>&1 ||
      { echo 'Invalid retired SMART incident history; refusing overwrite.' >&2; return 1; }
    cp "$BASE/retired-smart-incidents.json" "$WORK/retired-old" || return 1
  else
    echo '{}' > "$WORK/retired-old"
  fi
  jq -n --slurpfile archived "$WORK/retired-old" --slurpfile previous "$WORK/old" --slurpfile current "$WORK/events" '
    reduce ($current[0]|to_entries[]) as $e ($archived[0];
      ($previous[0][$e.key] // {}) as $p |
      if $p.bad==true and ($p.drive_id|type)=="string" and $p.drive_id!="" and
         ($e.value.drive_id|type)=="string" and $e.value.drive_id!="" and
         $e.value.drive_id!=$p.drive_id then
        .[($e.key+"|"+$p.drive_id)]=$p
      else . end)' > "$WORK/retired-next" || return 1
  if ! cmp -s "$WORK/retired-next" "$WORK/retired-old"; then
    cp "$WORK/retired-next" "$BASE/retired-smart-incidents.json.tmp" &&
      mv "$BASE/retired-smart-incidents.json.tmp" "$BASE/retired-smart-incidents.json" || return 1
  fi
  jq -s '.[0] * .[1]' "$WORK/old" "$WORK/events" > "$WORK/new" || return 1
  if ! cmp -s "$WORK/new" "$BASE/state.json"; then
    cp "$WORK/new" "$BASE/state.json.tmp" && mv "$BASE/state.json.tmp" "$BASE/state.json" || return 1
  fi
}
ai() {
  jq -n --arg model "$OLLAMA_MODEL" --rawfile report "$WORK/report" '{model:$model,stream:false,keep_alive:0,
    system:"Summarize only the supplied readings in three short sentences. No invented causes, numbers, or overall health verdict. No tools or commands. State that automatic SMART self-tests and a full security assessment are not included; mention SMART health only if the supplied report includes it.",
    prompt:$report,options:{temperature:0,num_ctx:2048,num_predict:160}}' > "$WORK/request"
  printf '\nOptional AI commentary (verify against readings):\n'
  if curl --silent --fail --connect-timeout 5 --max-time 180 "$OLLAMA_URL" \
    -H 'Content-Type: application/json' --data-binary @"$WORK/request" -o "$WORK/answer"; then
    jq -er 'select(.done==true) | .response | select(type=="string" and length>0)' "$WORK/answer" || echo 'AI returned no usable summary.'
  else echo 'AI unavailable; measured readings remain valid.'; fi
}
collect_disks() {
  local disks=${WATCHMAN_DISKS_INI:-/var/local/emhttp/disks.ini}
  local vars=${WATCHMAN_VAR_INI:-/var/local/emhttp/var.ini}
  rm -f -- "$WORK/disks"
  if [[ ! -r $disks || ! -r $vars ]]; then
    echo '{"disk_feed":{"bad":true,"message":"Unraid disk status files unavailable"}}' > "$WORK/disk-events"
    echo 'Unraid disk status: UNKNOWN' >> "$WORK/report"
  else
    # Parse INI as data, never source/eval. Sections and fields may be reordered.
    jq -Rn '
      def clean: gsub("^\\s+|\\s+$";"") | sub("^\"";"") | sub("\"$";"");
      reduce inputs as $l ({section:"global",data:{}};
        if ($l|test("^\\[.*\\]\\s*$")) then .section=($l|sub("^\\[";"")|sub("\\]\\s*$";"")|clean)
        elif ($l|test("^[A-Za-z][A-Za-z0-9_]*=")) then ($l|index("=")) as $i |
          .data[.section][$l[0:$i]]=($l[$i+1:]|clean)
        else . end) | .data' "$disks" > "$WORK/disks" || return 1
    jq -Rn 'reduce inputs as $l ({}; if ($l|test("^mdState=")) then .state=($l|sub("^mdState=";"")|gsub("[\"\\r]";"")) else . end)' "$vars" > "$WORK/array" || return 1
    jq -n --argjson disk_names "$WATCHMAN_DISKS" --argjson temp_limits "$WATCHMAN_DISK_TEMP_LIMITS" --argjson temp_default "$WATCHMAN_DISK_TEMP_DEFAULT" --slurpfile disks "$WORK/disks" --slurpfile arr "$WORK/array" '
      def event($b;$m):{bad:$b,message:$m};
      def num: try tonumber catch null;
      ($arr[0].state // "UNKNOWN") as $state |
      {disk_feed:event(($disks[0]|length)==0;"Unraid cached disk records available: \(($disks[0]|length)>0)"),
       array_state:event($state!="STARTED";"Array state: \($state); parity configuration not assessed")}
      + {parity_parity:event(
          (($disks[0].parity.device // "") != "") and (($disks[0].parity.status // "") != "DISK_OK");
          "parity: "+(if ($disks[0].parity.device // "") == "" then "not assigned" else "assigned; status "+($disks[0].parity.status // "UNKNOWN")+" (protection unverified)" end)),
         parity_parity2:event(
          (($disks[0].parity2.device // "") != "") and (($disks[0].parity2.status // "") != "DISK_OK");
          "parity2: "+(if ($disks[0].parity2.device // "") == "" then "not assigned" else "assigned; status "+($disks[0].parity2.status // "UNKNOWN")+" (protection unverified)" end))}
      + (reduce $disk_names[] as $name ({};
        ($disks[0][$name] // {}) as $d |
        ($temp_limits[$name] // $temp_default) as $tw |
        .["disk_"+$name+"_present"]=event(($d.device // "")=="";"\($name): \(if ($d.device // "")=="" then "expected device assignment missing" else "device assigned" end)") |
        if ($d.device // "")!="" then
          (if $state=="STARTED" then
            .["disk_"+$name+"_status"]=event($d.status!="DISK_OK";"\($name) status: \($d.status // "UNKNOWN")") |
            .["disk_"+$name+"_mount"]=event((($name|test("^parity[0-9]*$"))|not) and $d.fsStatus!="Mounted";"\($name) filesystem: \($d.fsStatus // "UNKNOWN")")
           else . end) |
          (if ($d.numErrors|num)!=null then
            .["disk_"+$name+"_errors"]=event(($d.numErrors|num)>0;"\($name) Unraid error counter: \($d.numErrors) (counter, not SMART)") else . end) |
          (if ($d.temp|num)!=null then
            .["disk_"+$name+"_temp"]=event(($d.temp|num)>=$tw;"\($name) temperature \($d.temp) C; configured warning \($tw) C") else . end) |
          (if ($d.fsSize|num)>0 and ($d.fsFree|num)!=null and $d.fsStatus=="Mounted" then
            (100*(1-($d.fsFree|num)/($d.fsSize|num))) as $used |
            .["disk_"+$name+"_space"]=event($used>=90;"\($name) filesystem \($used|floor)% used; warning 90%") else . end)
        else . end))' > "$WORK/disk-events" || return 1
    # Historical non-SMART disk incidents belong to the physical disk too.
    # Names are exact configured section names; never include IDs in messages.
    jq --argjson names "$WATCHMAN_DISKS" --slurpfile disks "$WORK/disks" '
      reduce $names[] as $n (.;
        with_entries(if (.key|startswith("disk_"+$n+"_")) and
                        (($disks[0][$n].id // "")!="")
          then .value.drive_id=$disks[0][$n].id else . end))' \
      "$WORK/disk-events" > "$WORK/disk-events-with-ids" || return 1
    mv "$WORK/disk-events-with-ids" "$WORK/disk-events" || return 1
    jq -nr --argjson disk_names "$WATCHMAN_DISKS" --slurpfile d "$WORK/disks" --slurpfile a "$WORK/array" '
      "Array: \($a[0].state // "UNKNOWN"); parity configuration not assessed.",
      (["parity","parity2"][] as $n | ($d[0][$n] // {}) as $v |
        "\($n) assignment: \(if ($v.device // "")=="" then "not assigned" else "assigned; status "+($v.status // "UNKNOWN")+" (parity protection not verified)" end)"),
      ($disk_names[] as $n | ($d[0][$n] // {}) as $v |
       "\($n): \($v.status // "UNKNOWN"), \($v.fsStatus // "UNKNOWN"); temp \(if ($v.temp // "*")=="*" then "unavailable (may be asleep)" else ($v.temp+" C") end); errors \($v.numErrors // "unknown"); used \(if (try ($v.fsSize|tonumber) catch 0)>0 and (try ($v.fsFree|tonumber) catch null)!=null then ((100*(1-($v.fsFree|tonumber)/($v.fsSize|tonumber))|floor|tostring)+"%") else "unknown" end)")' >> "$WORK/report"
  fi
  jq -s '.[0]+.[1]' "$WORK/events" "$WORK/disk-events" > "$WORK/merged" && mv "$WORK/merged" "$WORK/events" || return 1
  if [[ -r ${WATCHMAN_SYSLOG:-/var/log/syslog} ]]; then
    jq '.syslog_feed={bad:false,message:"System log readable"}' "$WORK/events" > "$WORK/merged"
  else
    jq '.syslog_feed={bad:true,message:"System log unavailable; event coverage interrupted"}' "$WORK/events" > "$WORK/merged"
  fi
  mv "$WORK/merged" "$WORK/events"
  printf 'Coverage: cached disk status + new matching syslog events. No SMART tests, full security audit, or automatic repairs.\n' >> "$WORK/report"
}
# Opt-in SMART observation. Snapshots are cached for alert modes, not refreshed each
# minute. smartctl uses "-n standby" and the helper skips USB transports entirely.
# Unavailable/sleeping disks produce no "healthy" event and cannot clear an alert.
collect_smart() {
  [[ $SMART_ENABLED == 1 ]] || return 0
  # WORK persists across --watch cycles; never reuse a prior cycle after a
  # collector error or missing disk metadata.
  rm -f -- "$WORK/smart-refreshed" "$WORK/smart-sample-valid" "$WORK/smart.json"
  [[ -s $WORK/disks ]] || { echo 'SMART: UNKNOWN (Unraid disk metadata unavailable).' >> "$WORK/report"; return 0; }
  local now last=0 refresh=1 cache_allowed=0
  now=$(date +%s)
  # The slot name alone is not a disk identity: require a nonempty Unraid id and
  # compare the full assigned identity list before EVER reusing an hourly sample.
  jq -cS '[to_entries[] | select((.value.type | IN("Parity","Data","Cache")) and
    ((.value.device // "") | test("^(sd[a-z]+|nvme[0-9]+n[0-9]+)$"))) |
    {name:.key,type:.value.type,device:.value.device,id:(.value.id // "")}] | sort_by(.name)' \
    "$WORK/disks" > "$WORK/smart-identity.json" || return 1
  if jq -e 'length>0 and all(.[];(.id|type)=="string" and .id!="")' "$WORK/smart-identity.json" >/dev/null; then
    cache_allowed=1
  fi
  if [[ $MODE == --watch || $MODE == --once ]] && (( cache_allowed )) &&
     [[ -s $BASE/smart-snapshot.json && -r $BASE/smart-snapshot-at && -s $BASE/smart-snapshot-identity.json ]] &&
     cmp -s "$WORK/smart-identity.json" "$BASE/smart-snapshot-identity.json"; then
    local cache_issue=''
    if ! jq -e 'type=="array" and length<=64 and all(.[];
      (.name|type)=="string" and (.id|type)=="string" and (.device|type)=="string" and
      (.status|IN("ok","unknown","standby")))' "$BASE/smart-snapshot.json" >/dev/null 2>&1; then
      cache_issue=smart-snapshot.json
    else
      read -r last < "$BASE/smart-snapshot-at" || :
      [[ $last =~ ^[0-9]{1,12}$ ]] || cache_issue=smart-snapshot-at
    fi
    if [[ -n $cache_issue ]]; then
      # A single corrupt SMART cache must never stop RAM, disk or syslog alerts.
      # Retain one local copy for diagnosis; if it cannot be copied, don't
      # overwrite the original with a new sample.
      echo "SMART cache invalid ($cache_issue); collecting fresh data if available." >> "$WORK/report"
      if [[ ! -e $BASE/$cache_issue.invalid ]]; then
        cp -p -- "$BASE/$cache_issue" "$BASE/$cache_issue.invalid" || cache_allowed=0
      fi
    elif (( now >= last && now-last < SMART_INTERVAL )); then
      if cp "$BASE/smart-snapshot.json" "$WORK/smart.json"; then
        refresh=0
        : > "$WORK/smart-sample-valid"
        echo "SMART: cached reading from $((now-last)) seconds ago." >> "$WORK/report"
      fi
    fi
  fi
  if (( refresh )); then
    if ! timeout 180 bash "$LOCAL_SMART" "$WORK/disks" "$WATCHMAN_DISKS" > "$WORK/smart.json"; then
      echo 'SMART: UNKNOWN (collector failed; no alert recovery inferred).' >> "$WORK/report"
      return 0
    fi
    jq -e --slurpfile ds "$WORK/disks" 'type=="array" and length<=64 and all(.[];
       (.name|type)=="string" and (.name|test("^[A-Za-z0-9_.-]+$")) and
       (.id|type)=="string" and (.device|type)=="string" and
       (.id == ($ds[0][.name].id // "")) and (.device == ($ds[0][.name].device // "")) and
       (.class|IN("hdd","ssd","nvme")) and (.status|IN("ok","unknown","standby")))' "$WORK/smart.json" >/dev/null 2>&1 ||
       { echo 'SMART: UNKNOWN (invalid or mismatched collector output).' >> "$WORK/report"; return 0; }
    if [[ $(jq 'length' "$WORK/smart.json") == 0 ]]; then
      echo 'SMART: UNKNOWN (no eligible drives or SMART tools available).' >> "$WORK/report"
      return 0
    fi
    # Only validated snapshots (fresh or identity-checked cache) may be used
    # for trends. Cached data allows retrying a failed Discord delivery without
    # probing the same physical drive again before its hourly interval.
    : > "$WORK/smart-refreshed"
    : > "$WORK/smart-sample-valid"
    if [[ $MODE == --once || $MODE == --watch ]] && (( cache_allowed )); then
      cp "$WORK/smart.json" "$BASE/smart-snapshot.json.tmp" &&
        mv "$BASE/smart-snapshot.json.tmp" "$BASE/smart-snapshot.json" || return 1
      cp "$WORK/smart-identity.json" "$BASE/smart-snapshot-identity.json.tmp" &&
        mv "$BASE/smart-snapshot-identity.json.tmp" "$BASE/smart-snapshot-identity.json" || return 1
      printf '%s\n' "$now" > "$BASE/smart-snapshot-at.tmp" &&
        mv "$BASE/smart-snapshot-at.tmp" "$BASE/smart-snapshot-at" || return 1
    fi
  fi
  jq -r '.[] | "SMART \(.name) (\(.class)): " +
    (if .status!="ok" then (.status | ascii_upcase) + " (not assumed healthy)"
     else "self-assessment " + (if .smart_passed==true then "PASS" elif .smart_passed==false then "FAIL" else "UNKNOWN" end) +
      "; temp " + (if .temperature_c==null then "unknown" else (.temperature_c|tostring)+" C" end) +
      "; pending " + (.pending // "unknown" | tostring) + "; uncorrectable " + (.uncorrectable // "unknown" | tostring) +
      "; reallocated " + (.reallocated // "unknown" | tostring) + "; SATA CRC " + (.crc // "unknown" | tostring) +
      "; NVMe media errors " + (.nvme_media_errors // "unknown" | tostring)
     end)' "$WORK/smart.json" >> "$WORK/report" || return 1
  jq -n --slurpfile ds "$WORK/smart.json" \
    --argjson hw "$SMART_HDD_WARN" --argjson hc "$SMART_HDD_CRIT" \
    --argjson sw "$SMART_SSD_WARN" --argjson sc "$SMART_SSD_CRIT" \
    --argjson nw "$SMART_NVME_WARN" --argjson nc "$SMART_NVME_CRIT" \
    --argjson custom "$WATCHMAN_DISK_TEMP_LIMITS" \
    --argjson fallback "$WATCHMAN_DISK_TEMP_DEFAULT" '
    def event($bad;$message):{bad:$bad,message:$message};
    reduce $ds[0][] as $d ({};
      # No stable identity: retain readings for reports, but do not invent
      # a recovery or associate alerts with an unidentified physical drive.
      if $d.status=="standby" or (($d.id // "")=="") then .
      else ($d.name) as $n | ($d.class) as $c |
        (if $c=="hdd" then [$hw,$hc] elif $c=="ssd" then [$sw,$sc] else [$nw,$nc] end) as $limits |
        # Explicit per-disk limit wins; non-default global Unraid limit wins
        # next; otherwise retain the class-specific SMART warning threshold.
        ($custom[$n] // (if $fallback!=55 then $fallback else $limits[0] end)) as $warn |
        (if $limits[1]>$warn then $limits[1] else ([$warn+10,120]|min) end) as $crit |
        (if ($d.smart_passed|type)=="boolean" then
          .["smart_"+$n+"_health"]=event($d.smart_passed==false;"\($n) SMART self-assessment: \(if $d.smart_passed then "PASS" else "FAILED; check drive immediately" end)")
         else . end) |
        (if ($d.temperature_c|type)=="number" then
          .["disk_"+$n+"_temp"]=(if $d.temperature_c >= $crit then
             {bad:true,level:2,message:"\($n) SMART CRITICAL temperature \($d.temperature_c) C; threshold \($crit) C"}
           elif $d.temperature_c >= $warn then
             {bad:true,level:1,message:"\($n) SMART temperature \($d.temperature_c) C; warning threshold \($warn) C"}
           else {bad:false,level:0,message:"\($n) SMART temperature \($d.temperature_c) C; below warning threshold \($warn) C"} end)
         else . end) |
        (if ($d.pending|type)=="number" then
          .["smart_"+$n+"_pending"]=event($d.pending>0;"\($n) SMART pending sectors: \($d.pending) (nonzero requires attention)")
         else . end) |
        (if ($d.uncorrectable|type)=="number" then
          .["smart_"+$n+"_uncorrectable"]=event($d.uncorrectable>0;"\($n) SMART offline uncorrectable sectors: \($d.uncorrectable)")
         else . end) |
        (if ($d.reported_uncorrectable|type)=="number" then
          .["smart_"+$n+"_reported_uncorrectable"]=event($d.reported_uncorrectable>0;"\($n) SMART reported uncorrectable errors: \($d.reported_uncorrectable)")
         else . end) |
        (if ($d.nvme_critical_warning|type)=="number" then
          .["smart_"+$n+"_nvme_critical"]=event($d.nvme_critical_warning>0;"\($n) NVMe critical warning flags: \($d.nvme_critical_warning)")
         else . end) |
        (if ($d.nvme_media_errors|type)=="number" then
          .["smart_"+$n+"_nvme_media"]=event($d.nvme_media_errors>0;"\($n) NVMe media error count: \($d.nvme_media_errors) (may be historical)")
         else . end) |
        # All per-drive SMART events (including the shared temperature key)
        # carry a local-only physical ID for identity-aware alert comparisons.
        with_entries(if ((.key|startswith("smart_"+$n+"_")) or .key=="disk_"+$n+"_temp")
          then .value.drive_id=$d.id else . end)
      end)' > "$WORK/smart-events.json" || return 1
  jq -s '.[0]+.[1]' "$WORK/events" "$WORK/smart-events.json" > "$WORK/smart-merged.json" &&
    mv "$WORK/smart-merged.json" "$WORK/events" || return 1
}
# One reconciled temperature event per physical drive. Prefer Unraid's current
# cached temperature to an hourly-old SMART temperature. When SMART is missing
# or a drive is asleep, keep its last known class (but NEVER its old temperature)
# so source changes cannot silently change warning limits or clear an alert.
reconcile_temps() {
  [[ -s $WORK/disks ]] || return 0
  local profile="$WORK/temp-smart-profile.json"
  echo '[]' > "$profile"
  if [[ $SMART_ENABLED == 1 ]]; then
    if [[ -f $WORK/smart-sample-valid && -s $WORK/smart.json ]]; then
      cp "$WORK/smart.json" "$profile" || return 1
    elif [[ -s $BASE/smart-snapshot.json ]] &&
      jq -e 'type=="array" and length<=64 and all(.[];
        (.name|type)=="string" and (.id|type)=="string" and
        (.device|type)=="string" and (.class|IN("hdd","ssd","nvme")))' \
        "$BASE/smart-snapshot.json" >/dev/null 2>&1; then
      cp "$BASE/smart-snapshot.json" "$profile" || return 1
    fi
  fi
  # If all SMART classification is unavailable (first run, USB, corrupt
  # snapshot), do not invent HDD critical limits or clear an active alert.
  echo '{}' > "$WORK/temp-prior.json"
  if [[ -f $BASE/state.json ]] &&
    jq -e 'type=="object" and all(.[]; (.bad|type)=="boolean")' "$BASE/state.json" >/dev/null 2>&1; then
    cp "$BASE/state.json" "$WORK/temp-prior.json" || return 1
  fi
  jq -n --slurpfile disks "$WORK/disks" --slurpfile smart "$profile" --slurpfile prior "$WORK/temp-prior.json" \
    --argjson selected "$WATCHMAN_DISKS" --argjson custom "$WATCHMAN_DISK_TEMP_LIMITS" \
    --argjson fallback "$WATCHMAN_DISK_TEMP_DEFAULT" \
    --argjson explicit "$DISK_TEMP_GLOBAL_EXPLICIT" --argjson enabled "$SMART_ENABLED" \
    --argjson hw "$SMART_HDD_WARN" --argjson hc "$SMART_HDD_CRIT" \
    --argjson sw "$SMART_SSD_WARN" --argjson sc "$SMART_SSD_CRIT" \
    --argjson nw "$SMART_NVME_WARN" --argjson nc "$SMART_NVME_CRIT" '
    def num: try tonumber catch null;
    def ev($n;$id;$temp;$src;$warn;$crit):
      (if $crit!=null and $temp >= $crit then 2 elif $temp >= $warn then 1 else 0 end) as $lvl |
      {bad:($lvl>0),level:$lvl,drive_id:$id,
       message:("\($n) \(if $lvl==2 then "CRITICAL " else "" end)temperature \($temp) C (\($src)); \(if $lvl==2 then "critical threshold \($crit) C" else "warning threshold \($warn) C" end)")};
    (($selected + (if $enabled==1 then ["parity","parity2"] else [] end)) | unique) as $names |
    reduce $names[] as $n ({};
      ($disks[0][$n] // {}) as $d |
      ([ $smart[0][] | select(.name==$n and .id==($d.id // "") and .device==($d.device // "") and
        (.class|IN("hdd","ssd","nvme"))) ] | first // {}) as $sm |
      ($d.temp|num) as $live |
      (if ($live|type)=="number" then $live
       elif $sm.status=="ok" and ($sm.temperature_c|type)=="number" then $sm.temperature_c
       else null end) as $temp |
      (if ($live|type)=="number" then "Unraid" else "SMART" end) as $src |
      ($sm.class|IN("hdd","ssd","nvme")) as $known_class |
      (if $sm.class=="ssd" then [$sw,$sc] elif $sm.class=="nvme" then [$nw,$nc]
       elif $sm.class=="hdd" then [$hw,$hc] else [$fallback,null] end) as $limits |
      ($custom[$n] // (if $explicit==1 then $fallback elif $enabled==1 and $known_class then $limits[0] else $fallback end)) as $warn |
      (if $enabled!=1 or ($known_class|not) then null
       elif $limits[1]>$warn then $limits[1] else ([$warn+10,120]|min) end) as $crit |
      ($prior[0]["disk_"+$n+"_temp"] // {}) as $old |
      if ($d.device // "")!="" and ($temp|type)=="number" and $temp>=-50 and $temp<=200 then
        if $enabled==1 and ($known_class|not) and $old.bad==true and
           ((($old.drive_id|type)!="string") or ($old.drive_id=="") or ($old.drive_id==($d.id // ""))) then
          # No comparable class-specific temperature limit: preserve active
          # incident instead of emitting a false recovery/de-escalation.
          .
        else .["disk_"+$n+"_temp"]=ev($n;($d.id // "");$temp;$src;$warn;$crit)
        end
      else . end)' > "$WORK/reconciled-temps.json" || return 1
  # Remove the preliminary temperature keys from both collectors. A missing
  # reading must never generate a fresh "all clear" to an older alert.
  jq -s '(.[0] | with_entries(select((.key|test("^disk_.*_temp$"))|not))) + .[1]' \
    "$WORK/events" "$WORK/reconciled-temps.json" > "$WORK/reconciled-events.json" || return 1
  mv "$WORK/reconciled-events.json" "$WORK/events"
}
# Historical counters can be nonzero for years; only increases on the SAME
# physical disk are new events. Baselines advance after successful delivery.
# No recovery notifications are generated for monotonic counters.
scan_smart_trends() {
  [[ $SMART_ENABLED == 1 && -f $WORK/smart-sample-valid && -s $WORK/smart.json ]] || return 0
  if [[ -f $BASE/smart-trends.json ]]; then
    jq -e 'type=="object" and all(.[]; (.id|type)=="string" and
      (.reallocated == null or (.reallocated|type)=="number") and
      (.crc == null or (.crc|type)=="number"))' "$BASE/smart-trends.json" >/dev/null 2>&1 ||
      { echo 'Invalid SMART trend history; refusing overwrite.' >&2; return 1; }
  else
    echo '{}' > "$WORK/smart-trends-old"
  fi
  local old=${BASE}/smart-trends.json notice
  [[ -f $old ]] || old=$WORK/smart-trends-old
  jq -n --slurpfile old "$old" --slurpfile readings "$WORK/smart.json" '
    reduce $readings[0][] as $d ({next:$old[0],notices:[]};
      if ($d.status=="standby" or ($d.id // "")=="") then .
      elif (($d.reallocated|type)!="number" and ($d.crc|type)!="number") then .
      else
        ($d.name) as $n |
        (if .next[$n].id==$d.id then .next[$n] else {id:$d.id} end) as $previous |
        (if ($d.reallocated|type)=="number" and ($previous.reallocated|type)!="number" and $d.reallocated>0 then
          .notices += ["SMART WARNING: \($n) has \($d.reallocated) reallocated sectors on initial observation of this physical drive. Inspect the drive."]
         elif ($d.reallocated|type)=="number" and ($previous.reallocated|type)=="number" and $d.reallocated>$previous.reallocated then
          .notices += ["SMART WARNING: \($n) reallocated sectors increased: \($previous.reallocated) -> \($d.reallocated). Inspect the drive."]
         elif ($d.reallocated|type)=="number" and ($previous.reallocated|type)=="number" and $d.reallocated<$previous.reallocated then
          .notices += ["SMART COUNTER ANOMALY: \($n) reallocated sector counter decreased: \($previous.reallocated) -> \($d.reallocated). Verify SMART identity and readings."]
         else . end) |
        (if ($d.crc|type)=="number" and ($previous.crc|type)=="number" and $d.crc>$previous.crc then
          .notices += ["SATA CONNECTION WARNING: \($n) CRC errors increased: \($previous.crc) -> \($d.crc). Check cable/connection."]
         else . end) |
        .next[$n]={id:$d.id,
          reallocated:(if ($d.reallocated|type)=="number" then $d.reallocated else $previous.reallocated // null end),
          crc:(if ($d.crc|type)=="number" then $d.crc else $previous.crc // null end)}
      end)' > "$WORK/smart-trend-result" || return 1
  notice=$(jq -r '.notices | join("\n")' "$WORK/smart-trend-result") || return 1
  if [[ -n $notice ]]; then
    send "NAS Watchman - ${WATCHMAN_HOSTNAME} SMART trends
$notice
Compared with previous successful reading of the same physical drive. No automatic tests or repairs." || return 1
  fi
  jq '.next' "$WORK/smart-trend-result" > "$WORK/smart-trends-next" || return 1
  if ! cmp -s "$WORK/smart-trends-next" "$BASE/smart-trends.json"; then
    cp "$WORK/smart-trends-next" "$BASE/smart-trends.json.tmp" &&
      mv "$BASE/smart-trends.json.tmp" "$BASE/smart-trends.json" || return 1
  fi
}
# Drive identity changes (replaced, moved, added, removed) are one-shot notices, like syslog events.
# Identity is Unraid's cached id= (model_serial) for every slot that has one, parity and flash included.
# The baseline advances only after delivery succeeds, so a failed send is retried on the next pass.
# First run records a baseline silently. Unreadable or id-less disk data never counts as "removed".
# Only compared while the array is STARTED: swaps done while stopped are reported once it starts,
# and slots that read differently while stopped can't raise false removals.
scan_disk_changes() {
  local notice
  [[ -s $WORK/disks ]] || return 0
  [[ $(jq -r '.state // ""' "$WORK/array" 2>/dev/null) == STARTED ]] || return 0
  jq -c 'with_entries(select(.key!="global" and (.value.id // "")!="") | .value={id:.value.id,type:(.value.type // "")})' "$WORK/disks" > "$WORK/disk-ids" || return 1
  [[ $(jq 'length' "$WORK/disk-ids") -gt 0 ]] || return 0
  if [[ ! -f $BASE/disk-ids.json ]]; then
    cp "$WORK/disk-ids" "$BASE/disk-ids.json.tmp" && mv "$BASE/disk-ids.json.tmp" "$BASE/disk-ids.json"
    return
  fi
  jq -e 'type=="object" and all(.[]; (.id|type)=="string" and (.type|type)=="string")' "$BASE/disk-ids.json" >/dev/null 2>&1 || { echo 'Invalid disk-ids.json; inspection needed.' >&2; return 1; }
  notice=$(jq -rn --slurpfile old "$BASE/disk-ids.json" --slurpfile now "$WORK/disk-ids" --argjson monitored "$WATCHMAN_DISKS" '
    # Show model and last 4 serial characters only; full serials stay on the server.
    # USB devices (e.g. flash) carry a "-0:0" LUN suffix; drop it before taking the serial tail.
    def mask: sub("-[0-9]+:[0-9]+$";"") | split("_") as $p | if ($p|length)>1 then ($p[:-1]|join(" "))+" (serial ending "+($p[-1][-4:])+")" else "serial ending "+.[-4:] end;
    def kind($v): if $v.type!="" then " ["+$v.type+"]" else "" end;
    $old[0] as $o | $now[0] as $n |
    def was($id): [$o|to_entries[]|select(.value.id==$id)|.key] | if length>0 then " (previously in "+.[0]+")" else "" end;
    def unmonitored: if (.value.type=="Data" or .value.type=="Cache") and ((.key|IN($monitored[]))|not) then " Not monitored yet; rerun wizard discovery to include it." else "" end;
    ([$n|to_entries[] | select($o[.key]!=null and $o[.key].id!=.value.id) |
       "DISK CHANGE: \(.key)\(kind(.value)) drive changed from \($o[.key].id|mask) to \(.value.id|mask)\(was(.value.id)). Confirm this was intentional."]
     + [$n|to_entries[] | select($o[.key]==null) |
       "DISK ADDED: \(.key)\(kind(.value)) now has \(.value.id|mask)\(was(.value.id)).\(unmonitored)"]
     + [$o|to_entries[] | select($n[.key]==null) |
       "DISK REMOVED: \(.key)\(kind(.value)) no longer reports \(.value.id|mask)."]) | join("\n")') || return 1
  if [[ -n $notice ]]; then
    send "NAS Watchman - ${WATCHMAN_HOSTNAME} drive changes
$notice
Source: Unraid cached disk records. Watchman made no changes to storage." || return 1
  fi
  if ! cmp -s "$WORK/disk-ids" "$BASE/disk-ids.json"; then
    cp "$WORK/disk-ids" "$BASE/disk-ids.json.tmp" && mv "$BASE/disk-ids.json.tmp" "$BASE/disk-ids.json" || return 1
  fi
}
# GPU configuration changes are one-shot notices, like drive changes. Cards are tracked by nvidia-smi
# uuid (never sent), so re-numbering after a reboot is quiet; the notice names model and PCI bus.
# Local telemetry only (the sidecar reports one GPU). "No GPUs reported" needs two failed passes in a
# row, so one slow nvidia-smi under load can't cause a false alarm. Baseline advances only after delivery.
scan_gpu_changes() {
  local query detail notice misses=0
  [[ $METRICS_MODE == local && -s $WORK/metrics ]] || return 0
  query=$(jq -r '.gpu_query // ""' "$WORK/metrics" 2>/dev/null) || return 0
  detail=$(jq -r '.gpu_error // ""' "$WORK/metrics" 2>/dev/null) || detail=''
  case "$query" in
    ok) jq -c '[.gpus[] | select((.uuid // "")!="") | {uuid,name,bus_id}] | sort_by(.uuid)' "$WORK/metrics" > "$WORK/gpu-ids" || return 1
        rm -f -- "$BASE/gpu-misses" ;;
    error|none|absent)
        [[ -f $BASE/gpu-misses ]] && read -r misses < "$BASE/gpu-misses"
        [[ $misses =~ ^[0-9]+$ ]] || misses=0
        misses=$((misses+1)); printf '%s\n' "$misses" > "$BASE/gpu-misses"
        (( misses >= 2 )) || return 0
        echo '[]' > "$WORK/gpu-ids" ;;
    *) return 0 ;;
  esac
  if [[ ! -f $BASE/gpu-ids.json ]]; then
    cp "$WORK/gpu-ids" "$BASE/gpu-ids.json.tmp" && mv "$BASE/gpu-ids.json.tmp" "$BASE/gpu-ids.json"
    return
  fi
  jq -e 'type=="array" and all(.[]; (.uuid|type)=="string")' "$BASE/gpu-ids.json" >/dev/null 2>&1 || { echo 'Invalid gpu-ids.json; inspection needed.' >&2; return 1; }
  notice=$(jq -rn --slurpfile old "$BASE/gpu-ids.json" --slurpfile now "$WORK/gpu-ids" --arg query "$query" --arg detail "$detail" '
    def card: "\(.name // "unknown GPU") (PCI \(.bus_id // "?" | sub("^0+:";"")))";
    $old[0] as $o | $now[0] as $n | ($o|map(.uuid)) as $ou | ($n|map(.uuid)) as $nu |
    ([ $o[] | select(.uuid | IN($nu[]) | not) | "GPU REMOVED: \(card) no longer reported." ]
     + [ $n[] | select(.uuid | IN($ou[]) | not) | "GPU ADDED: \(card) now reported." ]) as $lines |
    if ($lines|length)==0 then ""
    else (["GPU configuration changed: \($o|length) card(s) before, \($n|length) now."]
          + (if ($n|length)==0 then [{absent:"nvidia-smi is not installed or not on PATH",
                                      error:"nvidia-smi query FAILED (\($detail)); GPU state unknown",
                                      none:"nvidia-smi ran successfully but reported ZERO GPUs"}[$query]
                                     + " on two consecutive checks."] else [] end)
          + $lines) | join("\n") end') || return 1
  if [[ -n $notice ]]; then
    send "NAS Watchman - ${WATCHMAN_HOSTNAME}
$notice
Source: nvidia-smi. Watchman made no changes." || return 1
  fi
  if ! cmp -s "$WORK/gpu-ids" "$BASE/gpu-ids.json"; then
    cp "$WORK/gpu-ids" "$BASE/gpu-ids.json.tmp" && mv "$BASE/gpu-ids.json.tmp" "$BASE/gpu-ids.json" || return 1
  fi
}
scan_logs() {
  local file=${WATCHMAN_SYSLOG:-/var/log/syslog} inode size boot oldinode oldboot offset count taken notice gap=''
  [[ -r $file ]] || return 0
  inode=$(stat -c '%d:%i' "$file") || return 1
  size=$(stat -c %s "$file") || return 1
  boot=$(cat "${WATCHMAN_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}") || return 1
  # First run/new boot starts at EOF; historical events are not replayed.
  offset=$size
  if [[ -f $BASE/log-cursor.json ]]; then
    jq -e '(.offset|type)=="number" and .offset>=0 and (.inode|type)=="string" and (.boot|type)=="string"' "$BASE/log-cursor.json" >/dev/null || { echo 'Invalid log cursor; inspection needed.' >&2; return 1; }
    oldinode=$(jq -r .inode "$BASE/log-cursor.json")
    oldboot=$(jq -r .boot "$BASE/log-cursor.json")
    if [[ $boot == "$oldboot" ]]; then
      offset=$(jq -r .offset "$BASE/log-cursor.json")
      if [[ $inode != "$oldinode" ]] || (( size < offset )); then
        offset=0
        gap='Log rotated/truncated; checking current file. Unread events in old files may be missed.'
      fi
    fi
  fi
  count=$((size-offset))
  # Bound work per scan; excess remains queued for the next pass.
  (( count <= 1048576 )) || count=1048576
  : > "$WORK/log-new"
  if (( count > 0 )); then
    timeout 10 dd if="$file" of="$WORK/log-chunk" iflag=skip_bytes,count_bytes skip="$offset" count="$count" status=none || return 1
    # Do not consume a final incomplete record.
    if [[ $(tail -c 1 "$WORK/log-chunk" | od -An -tu1 | tr -d ' ') == 10 ]]; then
      cp "$WORK/log-chunk" "$WORK/log-new"
    else
      sed '$d' "$WORK/log-chunk" > "$WORK/log-new"
    fi
  fi
  taken=$(wc -c < "$WORK/log-new")
  if (( count == 1048576 && taken == 0 )); then
    taken=$count
    gap="Oversized log record skipped (1 MiB); event coverage gap."
  fi
  notice=$(awk '
    /webgui: Successful login/ {web++; next}
    # One line per real login. Unraid sshd also logs "Accepted key ... found at" twice per login; not counted.
    /sshd(-session)?\[[0-9]+\]: Accepted (publickey|password|keyboard-interactive|hostbased|gssapi-[a-z-]+) for / {ssh++; next}
    /sshd(-session)?\[[0-9]+\]: (Failed password|Failed publickey|Invalid user)/ {fail++; next}
    /webgui:/ && tolower($0) ~ /(failed login|login failed|unsuccessful login|invalid password)/ {fail++; next}
    /kernel:.*NVRM: Xid/ {gpu++; next}
    /kernel:/ && tolower($0) ~ /(out of memory:|oom-kill:|killed process [0-9]+)/ {oom++; next}
    # UAS error recovery is a warning even when the array still reports DISK_OK.
    /kernel:/ && tolower($0) ~ /(uas_eh_(abort|device_reset|bus_reset|target_reset)_handler|uas:.*(abort|reset|error))/ {uas++; next}
    /kernel:/ && tolower($0) ~ /sd [0-9]+:[0-9]+:[0-9]+:[0-9]+:.*device offlined/ {offline++; next}
    # Reset/disconnect lines alone may describe non-storage USB devices; label separately.
    /kernel:/ && tolower($0) ~ /usb [0-9]+(-[0-9.]+)?:.*(reset (superspeed|super-speed|high-speed|full-speed|low-speed) usb device|usb disconnect)/ {usb++; next}
    # Unraid md write errors may disable an array disk without matching generic I/O patterns.
    /kernel:/ && tolower($0) ~ /md: disk[0-9]+ write error/ {mdwrite++; next}
    /kernel:/ && tolower($0) ~ /(i\/o error|buffer i\/o|blk_update_request:.*error|filesystem.*error|xfs.*(corrupt|error|shutdown)|btrfs.*(error|corrupt)|ext4-fs error|nvme.*(timeout|reset|fatal))/ {disk++; next}
    END {
      if(web) printf "LOGIN NOTICE: %d successful WebGUI login(s).\n",web;
      if(ssh) printf "LOGIN NOTICE: %d successful SSH login(s).\n",ssh;
      if(fail) printf "AUTH NOTICE: %d failed/invalid-user log entries; not proof of an intrusion.\n",fail;
      if(gpu) printf "GPU ERROR: %d NVIDIA Xid event(s).\n",gpu;
      if(oom) printf "MEMORY ERROR: %d OOM-related log entries.\n",oom;
      if(uas) printf "USB STORAGE WARNING: %d UAS abort/reset/recovery event(s). Check USB enclosure and kernel log.\n",uas;
      if(offline) printf "USB STORAGE CRITICAL: %d storage-device-offline event(s). Check array status immediately.\n",offline;
      if(usb) printf "USB TRANSPORT NOTICE: %d reset/disconnect event(s); may include non-storage USB devices.\n",usb;
      if(mdwrite) printf "ARRAY WRITE ERROR: %d Unraid md disk write-error event(s). Check array disk status immediately.\n",mdwrite;
      if(disk) printf "STORAGE ERROR: %d matching I/O/filesystem/NVMe log entries.\n",disk;
    }' "$WORK/log-new") || return 1
  if [[ -n $notice || -n $gap ]]; then
    send "NAS Watchman - new system-log events
$gap
$notice
Counts cover new log entries, not necessarily distinct incidents. Details stay in /var/log/syslog; no usernames, IPs, or raw logs sent." || return 1
  fi
  jq -n --arg inode "$inode" --arg boot "$boot" --argjson offset "$((offset+taken))" '{inode:$inode,boot:$boot,offset:$offset}' > "$WORK/cursor"
  if ! cmp -s "$WORK/cursor" "$BASE/log-cursor.json"; then
    cp "$WORK/cursor" "$BASE/log-cursor.json.tmp" && mv "$BASE/log-cursor.json.tmp" "$BASE/log-cursor.json" || return 1
  fi
}

if [[ $MODE == --test-notify ]]; then
  send "NAS Watchman - ${WATCHMAN_HOSTNAME}
Test message: alerts from this server will arrive in this channel." && echo 'Test message sent.'
  exit
fi
collect || exit 1
case "$MODE" in
  --report) cat "$WORK/report" ;;
  --send-report) send "$(cat "$WORK/report")" && echo 'Measured report sent.' ;;
  --ai) cat "$WORK/report"; ai ;;
  --once) check_alerts && scan_smart_trends && scan_disk_changes && scan_gpu_changes && scan_logs && echo 'Check complete. Only new alerts/recoveries are sent.' ;;
  --watch)
    echo "Watchman 0.4 candidate active. RAM threshold $RAM_WARN%; first GPU threshold $GPU_WARN C."
    # Stop requests (config reload, array stop) take effect between checks, so an alert that was
    # just sent is always recorded in state.json first and is never re-sent after a restart.
    stop_req=0
    trap 'stop_req=1' TERM INT
    while (( !stop_req )); do
      if check_alerts; then scan_smart_trends || true; fi
      scan_disk_changes || true
      scan_gpu_changes || true
      scan_logs || true
      now=$(date +%s)
      last=0
      [[ ! -f $BASE/last-report ]] || read -r last < "$BASE/last-report"
      [[ $last =~ ^[0-9]+$ ]] || last=0
      if (( now - last >= 86400 )); then
        if send "$(cat "$WORK/report")"; then printf '%s\n' "$now" > "$BASE/last-report"; fi
      fi
      # Keep the minute-long poll cadence, but use short, interruptible waits. On
      # some Bash/Unraid combinations SIGTERM is deferred while waiting on an
      # external sleep; a 60-second wait could exceed the supervisor stop deadline.
      # fd 9 is closed for every sleep so no descendant holds the worker lock.
      for (( idle=0; idle<60 && !stop_req; idle+=5 )); do
        sleep 5 9>&- & SLEEP_PID=$!
        wait "$SLEEP_PID" 2>/dev/null || :
        kill -0 "$SLEEP_PID" 2>/dev/null || SLEEP_PID=''
      done
      (( stop_req )) && break
      collect || exit 1
    done
    echo 'Watchman engine stopped cleanly.' ;;
esac

