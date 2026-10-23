#!/bin/bash
# NAS Watchman 0.4.3 development preview -- host Bash worker for the existing telemetry sidecar.
# --report: local readings; --send-report: Discord readings; --ai: local AI summary
# --once: one alert check; --watch: checks every minute and a report every 24h.
# Cached Unraid disk status and selected new syslog events; no SMART tests or repairs.
set -uo pipefail
umask 077
export LC_ALL=C
MODE=${1:---report}
case "$MODE" in --report|--send-report|--ai|--once|--watch) ;; *) echo 'Use --report, --send-report, --ai, --once, or --watch'; exit 2;; esac
BASE=${WATCHMAN_STATE_DIR:-/mnt/user/appdata/nas-watchman}
WEBHOOK_FILE=${WATCHMAN_WEBHOOK_FILE:-/boot/config/plugins/nas-watchman/discord-webhook}
METRICS_URL=${WATCHMAN_METRICS_URL:-http://127.0.0.1:8001/metrics}
METRICS_MODE=${WATCHMAN_METRICS_MODE:-sidecar}
LOCAL_COLLECTOR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/watchman_local_metrics.py"
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
WATCHMAN_DISK_TEMP_DEFAULT=${WATCHMAN_DISK_TEMP_DEFAULT:-55}
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
for number in "$GPU_WARN" "$RAM_WARN"; do
  [[ $number =~ ^[0-9]{1,3}$ ]] || { echo 'Thresholds must be whole numbers.'; exit 2; }
done
for tool in jq curl flock timeout dd stat awk base64; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool"; exit 1; }
done
mkdir -p "$BASE" || exit 1
if [[ $MODE == --watch || $MODE == --once ]]; then
  exec 9> "$BASE/worker.lock"
  flock -n 9 || { echo "Watchman worker already running."; exit 1; }
fi
WORK=$(mktemp -d /tmp/nas-watchman.XXXXXX) || exit 1
trap 'rm -rf -- "$WORK"' EXIT
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
    python3 "$LOCAL_COLLECTOR" > "$WORK/metrics" || metrics_ok=0
  else
    curl --silent --fail --connect-timeout 5 --max-time 20 "$METRICS_URL" -o "$WORK/metrics" || metrics_ok=0
  fi
  if (( metrics_ok )) &&
     jq -e 'type=="object" and (.memory.percent == null or (.memory.percent|type=="number" and .>=0 and .<=100)) and (.gpu|type=="object") and (.gpu.available|type=="boolean") and (if .gpu.available then (.gpu.temperature_c|type=="number" and .>=-50 and .<=200) else true end) and (.docker.available|type=="boolean") and (if .docker.available then (.docker.containers|type=="array" and all(.[]; (.name|type=="string") and (.status|type=="string"))) else true end)' "$WORK/metrics" >/dev/null 2>&1; then
    jq --argjson gw "$GPU_WARN" --argjson rw "$RAM_WARN" --argjson names "$WATCHMAN_CONTAINERS" '
      def check($bad;$msg): {bad:$bad,message:$msg};
      {telemetry:check(false;"Telemetry source reachable")}
       + (if (.memory.percent|type)=="number" then
           {ram:check(.memory.percent >= $rw;"RAM usage \(.memory.percent)% (warning >= \($rw)%)")}
          else {} end)
       + (if .gpu.available == true and (.gpu.temperature_c|type)=="number" then
           {gpu:check(.gpu.temperature_c >= $gw;"First GPU temperature \(.gpu.temperature_c) C (warning >= \($gw) C)")}
          else {} end)
       + (if .docker.available == true then
           {docker:check(false;"Docker telemetry available")}
          else {} end)
       + (if .docker.available == true and (.docker.containers|type)=="array" then
          .docker.containers as $cs | reduce $names[] as $n ({};
          .["container_"+$n]=check(([$cs[] | select(.name==$n and .status=="running")]|length)==0;"Container \($n): \(if ([$cs[]|select(.name==$n and .status=="running")]|length)>0 then "running" else "not reported running; may be intentionally stopped" end)"))
          else {} end)' "$WORK/metrics" > "$WORK/events" || return 1
    jq -r '"NAS Watchman - measured snapshot\nRAM: \(.memory.percent // "unknown")%\nFirst GPU: \(.gpu.temperature_c // "unknown") C; load \(.gpu.utilization_percent // "unknown")%; VRAM \(.gpu.memory_used_mb // "unknown") / \(.gpu.memory_total_mb // "unknown") MiB\nDocker readings available: \(.docker.available // false)\nRunning containers reported: \(if .docker.available then (.docker.containers|length) else "unknown" end)\nSidecar / filesystem usage: \(.disk.percent // "unknown")% (not verified as array usage)\nNo overall health verdict."' "$WORK/metrics" > "$WORK/report"
  else
    printf '%s\n' '{"telemetry":{"bad":true,"message":"Telemetry API unavailable or invalid; other checks unknown"}}' > "$WORK/events"
    printf 'NAS Watchman: telemetry unavailable. Other checks unknown.\n' > "$WORK/report"
  fi
  collect_disks
}
check_alerts() {
  local notice
  if [[ -f $BASE/state.json ]]; then
    jq -e 'type=="object" and all(.[]; (.bad|type)=="boolean")' "$BASE/state.json" >/dev/null 2>&1 || { echo 'Invalid state.json; refusing to discard alert history.' >&2; return 1; }
    cp "$BASE/state.json" "$WORK/old"
  else echo '{}' > "$WORK/old"; fi
  notice=$(jq -rn --slurpfile old "$WORK/old" --slurpfile now "$WORK/events" '
    $now[0] | to_entries | map(. as $e | $old[0][$e.key] as $p |
      select(($e.value.bad and ($p.bad != true)) or ($e.value.bad == false and $p.bad == true)) |
      (if .value.bad then "ALERT: " else "RECOVERY: " end) + .value.message) | join("\n")') || return 1
  if [[ -n $notice ]]; then
    send "NAS Watchman - ${WATCHMAN_HOSTNAME}
$notice" || return 1
  fi
  jq -s '.[0] * .[1]' "$WORK/old" "$WORK/events" > "$WORK/new" || return 1
  if ! cmp -s "$WORK/new" "$BASE/state.json"; then
    cp "$WORK/new" "$BASE/state.json.tmp" && mv "$BASE/state.json.tmp" "$BASE/state.json" || return 1
  fi
}
ai() {
  jq -n --arg model "$OLLAMA_MODEL" --rawfile report "$WORK/report" '{model:$model,stream:false,keep_alive:0,
    system:"Summarize only the supplied readings in three short sentences. No invented causes, numbers, or overall health verdict. No tools or commands. State that SMART health and a full security assessment are not included.",
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
      + (reduce ["parity","parity2"][] as $name ({};
          ($disks[0][$name] // {}) as $d |
          .["parity_"+$name] = event(
            (($d.device // "") != "" and ($d.status // "UNKNOWN") != "DISK_OK");
            "\($name): \(if ($d.device // "") == "" then "not assigned" elif $d.status == "DISK_OK" then "assigned, status OK (protection unverified)" else "assigned, status "+($d.status // "UNKNOWN") end)"
          )
        ))
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
scan_logs() {
  local file=${WATCHMAN_SYSLOG:-/var/log/syslog} inode size boot oldinode oldboot offset count taken notice gap=''
  [[ -r $file ]] || return 0
  inode=$(stat -c '%d:%i' "$file") || return 1
  size=$(stat -c %s "$file") || return 1
  boot=$(cat /proc/sys/kernel/random/boot_id) || return 1
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
    /sshd(-session)?\[[0-9]+\]: Accepted / {ssh++; next}
    /sshd(-session)?\[[0-9]+\]: (Failed password|Failed publickey|Invalid user)/ {fail++; next}
    /webgui:/ && tolower($0) ~ /(failed login|login failed|unsuccessful login|invalid password)/ {fail++; next}
    /kernel:.*NVRM: Xid/ {gpu++; next}
    /kernel:/ && tolower($0) ~ /(out of memory:|oom-kill:|killed process [0-9]+)/ {oom++; next}
    /kernel:/ && tolower($0) ~ /(i\/o error|buffer i\/o|blk_update_request:.*error|filesystem.*error|xfs.*(corrupt|error|shutdown)|btrfs.*(error|corrupt)|ext4-fs error|nvme.*(timeout|reset|fatal))/ {disk++; next}
    END {
      if(web) printf "LOGIN NOTICE: %d successful WebGUI login(s).\n",web;
      if(ssh) printf "LOGIN NOTICE: %d successful SSH login(s).\n",ssh;
      if(fail) printf "AUTH NOTICE: %d failed/invalid-user log entries; not proof of an intrusion.\n",fail;
      if(gpu) printf "GPU ERROR: %d NVIDIA Xid event(s).\n",gpu;
      if(oom) printf "MEMORY ERROR: %d OOM-related log entries.\n",oom;
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

collect || exit 1
case "$MODE" in
  --report) cat "$WORK/report" ;;
  --send-report) send "$(cat "$WORK/report")" && echo 'Measured report sent.' ;;
  --ai) cat "$WORK/report"; ai ;;
  --once) check_alerts && scan_logs && echo 'Check complete. Only new alerts/recoveries are sent.' ;;
  --watch)
    echo "Watchman 0.4 candidate active. RAM threshold $RAM_WARN%; first GPU threshold $GPU_WARN C."
    while :; do
      check_alerts || true
      scan_logs || true
      now=$(date +%s)
      last=0
      [[ ! -f $BASE/last-report ]] || read -r last < "$BASE/last-report"
      [[ $last =~ ^[0-9]+$ ]] || last=0
      if (( now - last >= 86400 )); then
        if send "$(cat "$WORK/report")"; then printf '%s\n' "$now" > "$BASE/last-report"; fi
      fi
      sleep 60 & wait $!
      collect || exit 1
    done ;;
esac

