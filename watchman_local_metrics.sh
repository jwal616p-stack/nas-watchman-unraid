#!/bin/bash
# Read-only local telemetry; emits the sidecar-compatible JSON shape on stdout.
# Needs only bash + jq + coreutils/awk (stock Unraid 7 ships these; it has no python3).
# Optional sources fail closed: a missing tool or unreadable file reports "unavailable", never healthy.
set -uo pipefail
export LC_ALL=C
MEMINFO=${WATCHMAN_MEMINFO:-/proc/meminfo}

mem=null
if [[ -r $MEMINFO ]]; then
  read -r total avail < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print (t==""?"x":t), (a==""?"x":a)}' "$MEMINFO")
  if [[ $total =~ ^[0-9]+$ && $avail =~ ^[0-9]+$ ]] && (( total > 0 && avail <= total )); then
    mem=$(awk -v t="$total" -v a="$avail" 'BEGIN{printf "%.2f", 100*(t-a)/t}')
  fi
fi

# Every NVIDIA GPU: "gpus" lists each card by index and name. A row nvidia-smi can't read (e.g. "[N/A]")
# is kept as available:false so that card raises an alert rather than silently vanishing.
# "gpu" keeps the sidecar contract (first GPU) for compatibility.
gpu='{"available":false}'
gpus='[]'
# gpu_query: absent = no nvidia-smi; error = it failed, timed out or printed unreadable output (gpu_error
# says which); none = it succeeded and reported zero GPUs; ok = at least one card listed.
gpu_query=absent
gpu_error=''
if command -v nvidia-smi >/dev/null 2>&1; then
  # Capture all output (never pipe to head: with several GPUs that fails under pipefail).
  # Name is queried last so a comma in a model name cannot shift the numeric fields.
  # uuid identifies a card across reboots/re-enumeration (used only for change detection, never sent).
  rc=0
  out=$(timeout 3 nvidia-smi --query-gpu=index,temperature.gpu,utilization.gpu,memory.used,memory.total,uuid,pci.bus_id,name \
         --format=csv,noheader,nounits 2>/dev/null) || { rc=$?; out=''; }
  gpus=$(jq -Rnc '
    def int: try (tonumber | if . == floor then . else null end) catch null;
    # Driver 620 reports fractional temperatures, e.g. 40.41 C. Keep
    # integer validation for indices/counters; parse only temperature as real.
    def temp: try tonumber catch null;
    [inputs | select(length>0) | split(",") | map(gsub("^\\s+|\\s+$";"")) as $f
     | ($f[0]|int) as $i | ($f[1]|temp) as $t | ($f[2]|int) as $u | ($f[3]|int) as $mu | ($f[4]|int) as $mt
     | {uuid:($f[5] // ""), bus_id:($f[6] // ""), name:($f[7:]|join(","))} as $id
     | if $i == null then empty
       elif ([$t,$u,$mu,$mt] | all(. != null)) and $t >= -50 and $t <= 200 then
         {index:$i,available:true,temperature_c:$t,utilization_percent:$u,memory_used_mb:$mu,memory_total_mb:$mt} + $id
       else {index:$i,available:false} + $id end]' <<<"$out" 2>/dev/null) || gpus='[]'
  gpu=$(jq -c 'if (.[0].available // false) then .[0] | del(.index,.name,.uuid,.bus_id) else {available:false} end' <<<"$gpus")
  if [[ $(jq 'length' <<<"$gpus") -gt 0 ]]; then gpu_query=ok
  elif (( rc == 6 )); then gpu_query=none    # nvidia-smi: "No devices were found" (query worked, zero GPUs)
  elif (( rc == 9 )); then gpu_query=error; gpu_error='NVIDIA driver not loaded (exit code 9)'
  elif (( rc == 124 )); then gpu_query=error; gpu_error='timed out after 3 s'
  elif (( rc != 0 )); then gpu_query=error; gpu_error="exit code $rc"
  elif [[ -n ${out//[[:space:]]/} ]]; then gpu_query=error; gpu_error='unreadable output'
  else gpu_query=none; fi
fi

docker='{"available":false,"containers":[]}'
if command -v docker >/dev/null 2>&1 && out=$(timeout 3 docker ps -a --format '{{.Names}}\t{{.State}}' 2>/dev/null); then
  docker=$(jq -Rnc '[inputs | select(length>0) | split("\t") |
      if length==2 and all(.[]; length>0) then {name:.[0],status:.[1]} else error("malformed docker row") end]
      | {available:true,containers:.}' <<<"$out" 2>/dev/null) || docker='{"available":false,"containers":[]}'
fi

jq -nc --argjson mem "$mem" --argjson gpu "$gpu" --argjson gpus "$gpus" --arg gq "$gpu_query" --arg ge "$gpu_error" --argjson docker "$docker" \
  '{memory:{percent:$mem},gpu:$gpu,gpus:$gpus,gpu_query:$gq,gpu_error:(if $ge=="" then null else $ge end),docker:$docker,disk:{percent:null},source:"watchman-local-readonly"}'
