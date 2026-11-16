#!/usr/bin/env bash
# NAS Watchman launcher and setup wizard (installed as 'watchman setup')
set -euo pipefail
umask 077
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DISPLAY_VERSION=$(head -n 1 "$HERE/VERSION" 2>/dev/null || echo development)
ENGINE="$HERE/watchman_engine.sh"
# New namespace: never the v0.3 folder /boot/config/plugins/nas-watchman.
CONFIG_DIR="${WATCHMAN_CONFIG_DIR:-/boot/config/plugins/watchman/config}"
WEBHOOK_FILE="${WATCHMAN_WEBHOOK_FILE:-$CONFIG_DIR/discord-webhook}"
export WATCHMAN_WEBHOOK_FILE="$WEBHOOK_FILE"
CONFIG="$CONFIG_DIR/watchman.json"
DISKS_INI="${WATCHMAN_DISKS_INI:-/var/local/emhttp/disks.ini}"
PENDING_CONFIG=''
reload_note() { [[ ${WATCHMAN_INSTALLED:-0} == 1 ]] && echo "Watchman will pick this up within a few seconds." || true; }
cleanup_pending() {
 [[ -z "$PENDING_CONFIG" ]] || rm -f -- "$PENDING_CONFIG"
}
trap cleanup_pending EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
usage() {
printf 'NAS Watchman %s (development)\n' "$DISPLAY_VERSION"
cat <<'EOF'
Usage: watchman.sh [--help|--report|--send-report|--ai|--once|--watch|--test-notify|--check-config]
No arguments with a terminal: setup menu.
No arguments without a terminal: read-only report.
Commands always bypass the wizard. When installed, saved changes reload the engine within seconds.
EOF
}
valid_config() {
 jq -e 'type=="object" and
 ((keys - ["version","disks","containers","gpu_warn","ram_warn","disk_temp_default","metrics_mode","ollama_model","smart_enabled"])|length==0) and
 (.version=="0.4.2") and
 ((.metrics_mode // "local") as $m | $m=="sidecar" or $m=="local") and
 ((.ollama_model // "llama3.2:1b")|type=="string" and length>=1 and length<=100 and test("^[A-Za-z0-9_.:/-]+$")) and
 (.disks|type=="array" and all(.[];type=="string" and length>0) and (unique|length)==length) and
 (.containers|type=="array" and all(.[];type=="string" and length>0) and (unique|length)==length) and
 ((.gpu_warn // 85)|type=="number" and .==floor and .>=0 and .<=100) and
 ((.ram_warn // 90)|type=="number" and .==floor and .>=0 and .<=100) and
 ((.disk_temp_default // 55)|type=="number" and .==floor and .>=1 and .<=120) and
 ((.smart_enabled // false)|type=="boolean")' "$1" >/dev/null
}
load_config() {
 [[ -f "$CONFIG" ]] || return 0
 command -v jq >/dev/null || { echo "jq required to load configuration" >&2; return 1; }
 valid_config "$CONFIG" || { echo "Invalid configuration: $CONFIG; refusing to run" >&2; if [[ -f "$CONFIG.bak" ]] && valid_config "$CONFIG.bak"; then echo "Valid backup available: use interactive Restore Previous Configuration." >&2; else echo "No valid backup; manual recovery required." >&2; fi; return 1; }
 export WATCHMAN_DISKS WATCHMAN_CONTAINERS GPU_WARN RAM_WARN WATCHMAN_DISK_TEMP_DEFAULT WATCHMAN_DISK_TEMP_DEFAULT_SET WATCHMAN_METRICS_MODE WATCHMAN_OLLAMA_MODEL WATCHMAN_SMART_ENABLED
 WATCHMAN_DISKS=$(jq -c '.disks' "$CONFIG")
 WATCHMAN_CONTAINERS=$(jq -c '.containers' "$CONFIG")
 GPU_WARN=$(jq -r '.gpu_warn // 85' "$CONFIG")
 RAM_WARN=$(jq -r '.ram_warn // 90' "$CONFIG")
 WATCHMAN_DISK_TEMP_DEFAULT=$(jq -r '.disk_temp_default // 55' "$CONFIG")
 WATCHMAN_DISK_TEMP_DEFAULT_SET=$(jq -r 'if has("disk_temp_default") then 1 else 0 end' "$CONFIG")
 WATCHMAN_METRICS_MODE=$(jq -r '.metrics_mode // "local"' "$CONFIG")
 WATCHMAN_OLLAMA_MODEL=$(jq -r '.ollama_model // "llama3.2:1b"' "$CONFIG")
 WATCHMAN_SMART_ENABLED=$(jq -r 'if .smart_enabled == true then 1 else 0 end' "$CONFIG")
}
banner() {
 cat <<'EOF' | sed "s/__WATCHMAN_VERSION__/$DISPLAY_VERSION/"
      / \__
     (    @\___   NAS WATCHMAN __WATCHMAN_VERSION__
     /         O  Chief Security Officer on Duty
    /   (_____/
   /_____/   U
EOF
}
# Parse Unraid disks.ini as data (same rules as the engine): quoted ["disk1"] or bare [disk1] headers.
parse_disks_ini() {
 jq -Rn '
  def clean: gsub("^\\s+|\\s+$";"") | sub("^\"";"") | sub("\"$";"");
  reduce inputs as $l ({section:"global",data:{}};
   if ($l|test("^\\[.*\\]\\s*$")) then .section=($l|sub("^\\[";"")|sub("\\]\\s*$";"")|clean)
   elif ($l|test("^[A-Za-z][A-Za-z0-9_]*=")) then ($l|index("=")) as $i |
    .data[.section][$l[0:$i]]=($l[$i+1:]|clean)
   else . end) | .data' "$1"
}
# Classify each section: array data disks and pool devices with a drive assigned are monitored.
# Parity is reported by the engine on every run, so it is never added to the disk list.
DISK_CLASSIFY='def classify: (.value.type // "") as $t | (.value.device // "") as $d |
  if .key=="global" then "skip:metadata"
  elif $t=="Parity" or (.key|test("^parity[0-9]*$")) then "skip:parity (always reported by engine)"
  elif $t=="Flash" or .key=="flash" then "skip:boot flash"
  elif $d=="" then "skip:empty slot"
  elif $t=="Data" or $t=="Cache" then "monitor"
  elif $t=="" and (.key|test("^disk[0-9]+$")) then "monitor"
  else "skip:unrecognized type \($t)" end;'
# Container picker. Default selection = containers set to autostart in Unraid (Docker tab), because
# those are the ones that are supposed to be running. Toggle by number. Sets SELECTED (JSON array).
AUTOSTART_FILE="${WATCHMAN_DOCKER_AUTOSTART:-/var/lib/docker/unraid-autostart}"
select_containers() {
 local names=() states=() sel=() toks=() i n s input tok
 local -A is_auto=()
 if [[ -r "$AUTOSTART_FILE" ]]; then
  while read -r n _; do [[ -n "$n" ]] && is_auto[$n]=1; done < "$AUTOSTART_FILE"
 fi
 while IFS=$'\t' read -r n s; do
  [[ -n "$n" ]] || continue
  names+=("$n"); states+=("${s:-unknown}")
 done < <(printf '%s\n' "$CONTAINER_ROWS" | sort -f -u)
 SELECTED='[]'
 (( ${#names[@]} )) || { echo "No containers found."; return 0; }
 _sel_defaults() { for i in "${!names[@]}"; do if [[ -n "${is_auto[${names[i]}]:-}" ]]; then sel[i]=1; else sel[i]=0; fi; done; }
 _sel_defaults
 if (( ${#is_auto[@]} == 0 )); then
  echo "Unraid has no containers set to autostart (Docker tab > Autostart), so none are preselected."
  echo "Tick the containers that should always be running."
 fi
 while :; do
  echo "Containers to watch ([x] = alert when not running):"
  for i in "${!names[@]}"; do
   printf ' %2d [%s] %-36s %s%s\n' "$((i+1))" "$( [[ ${sel[i]} == 1 ]] && echo x || echo ' ')" "${names[i]}" "${states[i]}" \
     "$( [[ -n "${is_auto[${names[i]}]:-}" ]] && echo ', autostart' || true)"
  done
  printf 'Toggle numbers (e.g. 2 5 7), a=all, n=none, d=autostart defaults, q=cancel, Enter=done: '
  read -r input || return 1
  [[ -n "${input//[[:space:]]/}" ]] || break
  read -r -a toks <<<"$input"
  for tok in "${toks[@]}"; do
   case "$tok" in
    a|A) for i in "${!names[@]}"; do sel[i]=1; done ;;
    n|N) for i in "${!names[@]}"; do sel[i]=0; done ;;
    d|D) _sel_defaults ;;
    q|Q) return 1 ;;
    *) if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#names[@]} )); then i=$((tok-1)); sel[i]=$((1-sel[i]))
       else echo "Ignored: $tok"; fi ;;
   esac
  done
 done
 SELECTED=$(for i in "${!names[@]}"; do if [[ ${sel[i]} == 1 ]]; then printf '%s\n' "${names[i]}"; fi; done | jq -R . | jq -sc 'map(select(length>0))')
}
discover() {
 local disks='[]' containers='[]' disk_ok=1 docker_ok=1 parsed skipped
 if [[ -r "$DISKS_INI" ]]; then
  if parsed=$(parse_disks_ini "$DISKS_INI") && jq -e 'type=="object"' >/dev/null <<<"$parsed"; then
   disks=$(jq -c "$DISK_CLASSIFY"' [to_entries[] | select(classify=="monitor") | .key] | unique' <<<"$parsed")
   skipped=$(jq -r "$DISK_CLASSIFY"' to_entries[] | classify as $c | select($c|startswith("skip:")) | select($c!="skip:metadata") | "  \(.key): \($c[5:])"' <<<"$parsed")
   [[ -z "$skipped" ]] || printf 'Not added to disk list:\n%s\n' "$skipped"
  else
   echo "Disk discovery unavailable (file unparseable)." >&2
   disk_ok=0
  fi
 else
  echo "Disk discovery unavailable (file unreadable)." >&2
  disk_ok=0
 fi
 if command -v docker >/dev/null; then
  CONTAINER_ROWS=$(docker ps -a --format '{{.Names}}\t{{.State}}' 2>/dev/null) || { echo "Docker discovery unavailable." >&2; docker_ok=0; CONTAINER_ROWS=''; }
 else
  echo "Docker discovery unavailable (Docker CLI missing)." >&2
  docker_ok=0
 fi
 printf 'Disks: %s\n' "$disks"
 if (( !disk_ok || !docker_ok )); then
  echo "Discovery incomplete. Nothing saved; please resolve unavailable sources." >&2
  return 0
 fi
 if [[ "$disks" == '[]' ]]; then
  echo "No array data disks or pool devices recognized in $DISKS_INI. Nothing saved; existing selections kept." >&2
  return 0
 fi
 select_containers || { echo "Canceled; nothing saved."; return 0; }
 containers=$SELECTED
 printf 'Containers: %s\n' "$containers"
 echo "Preview only: these selections will replace the existing disk/container selections."
 if [[ -f "$CONFIG" ]]; then
  valid_config "$CONFIG" || { echo "Existing configuration invalid; refusing overwrite." >&2; return 1; }
  printf 'Previous disks: %s\nPrevious containers: %s\n' "$(jq -c '.disks' "$CONFIG")" "$(jq -c '.containers' "$CONFIG")"
 fi
 printf 'Save these selections? [y/N] '
 read -r answer || return 0
 [[ "$answer" == [yY] ]] || { echo "Discarded."; return 0; }
 mkdir -p "$CONFIG_DIR"
 local tmp
 tmp=$(mktemp "$CONFIG_DIR/.watchman.XXXXXXXX") || return 1
 PENDING_CONFIG="$tmp"
 if [[ -f "$CONFIG" ]]; then
  valid_config "$CONFIG" || { echo "Existing config invalid; refusing overwrite" >&2; return 1; }
  jq --argjson disks "$disks" --argjson containers "$containers" '.disks=$disks | .containers=$containers' "$CONFIG" > "$tmp"
 else
  jq -n --argjson disks "$disks" --argjson containers "$containers" '{version:"0.4.2",disks:$disks,containers:$containers}' > "$tmp"
 fi
 valid_config "$tmp" || { echo "Generated config invalid" >&2; return 1; }
 if [[ -e "$CONFIG" ]]; then
  local backup
  backup=$(mktemp "$CONFIG_DIR/.watchman-backup.XXXXXXXX") || return 1
  cp -- "$CONFIG" "$backup" || { rm -f -- "$backup"; return 1; }
  chmod 600 "$backup"
  mv -f -- "$backup" "$CONFIG.bak" || return 1
 fi
 chmod 600 "$tmp"
 mv -f -- "$tmp" "$CONFIG"
 PENDING_CONFIG=''
 echo "Saved: $CONFIG (previous config backed up when present)"
 reload_note
}
restore_backup() {
 local backup="$CONFIG.bak" tmp answer
 if [[ ! -f "$backup" ]]; then
  echo "No saved backup available."
  return 0
 fi
 valid_config "$backup" || { echo "Backup invalid; refusing to restore." >&2; return 1; }
 echo "Backup contents:"
 jq '{disks,containers,metrics_mode,ollama_model,gpu_warn,ram_warn,disk_temp_default,smart_enabled}' "$backup"
 printf 'Restore this backup? [y/N] '
 read -r answer || return 0
 [[ "$answer" == [yY] ]] || { echo "Restore canceled."; return 0; }
 mkdir -p "$CONFIG_DIR"
 tmp=$(mktemp "$CONFIG_DIR/.watchman-restore.XXXXXXXX") || return 1
 PENDING_CONFIG="$tmp"
 cp -- "$backup" "$tmp" || return 1
 chmod 600 "$tmp"
 valid_config "$tmp" || return 1
 mv -f -- "$tmp" "$CONFIG"
 PENDING_CONFIG=''
 echo "Backup restored."
 reload_note
}
set_metrics_mode() {
 local mode answer tmp backup
 echo "Telemetry source: [1] Sidecar HTTP API (port 8001)  [2] Built-in local collector (default)"
 printf 'Select [1/2] (other cancels): '
 read -r answer || return 0
 case "$answer" in
  1) mode=sidecar ;;
  2) mode=local ;;
  *) echo "Canceled."; return 0 ;;
 esac
 if [[ -f "$CONFIG" ]]; then
  valid_config "$CONFIG" || { echo "Existing config invalid; refusing overwrite." >&2; return 1; }
  printf 'Current mode: %s\n' "$(jq -r '.metrics_mode // "local"' "$CONFIG")"
 fi
 printf 'Save telemetry mode %s? [y/N] ' "$mode"
 read -r answer || return 0
 [[ "$answer" == [yY] ]] || { echo "Discarded."; return 0; }
 mkdir -p "$CONFIG_DIR"
 tmp=$(mktemp "$CONFIG_DIR/.watchman.XXXXXXXX") || return 1
 PENDING_CONFIG="$tmp"
 if [[ -f "$CONFIG" ]]; then
  jq --arg mode "$mode" '.metrics_mode=$mode' "$CONFIG" > "$tmp"
 else
  jq -n --arg mode "$mode" '{version:"0.4.2",disks:[],containers:[],metrics_mode:$mode}' > "$tmp"
 fi
 valid_config "$tmp" || return 1
 if [[ -e "$CONFIG" ]]; then
  backup=$(mktemp "$CONFIG_DIR/.watchman-backup.XXXXXXXX") || return 1
  cp -- "$CONFIG" "$backup" || { rm -f -- "$backup"; return 1; }
  chmod 600 "$backup"
  mv -f -- "$backup" "$CONFIG.bak" || return 1
 fi
 chmod 600 "$tmp"
 mv -f -- "$tmp" "$CONFIG"
 PENDING_CONFIG=''
 echo "Saved telemetry mode: $mode"
 reload_note
}
set_smart_enabled() {
 local enabled answer tmp backup
 echo 'SMART reads are standby-safe and skip USB storage. No self-tests or repairs.'
 echo 'Monitoring adds SATA/NVMe health, pending sectors, and high-temperature alerts.'
 printf 'SMART monitoring: [1] Enable  [2] Disable (default); choice: '
 read -r answer || return 0
 case "$answer" in 1) enabled=true ;; 2) enabled=false ;; *) echo 'Canceled.'; return 0 ;; esac
 if [[ -f $CONFIG ]]; then
  valid_config "$CONFIG" || { echo 'Existing configuration invalid; refusing overwrite.' >&2; return 1; }
 fi
 printf 'Save SMART monitoring = %s? [y/N] ' "$enabled"
 read -r answer || return 0
 [[ $answer == [yY] ]] || { echo 'Discarded.'; return 0; }
 mkdir -p "$CONFIG_DIR"
 tmp=$(mktemp "$CONFIG_DIR/.watchman.XXXXXXXX") || return 1
 PENDING_CONFIG="$tmp"
 if [[ -f $CONFIG ]]; then
  jq --argjson enabled "$enabled" '.smart_enabled=$enabled' "$CONFIG" > "$tmp"
 else
  jq -n --argjson enabled "$enabled" '{version:"0.4.2",disks:[],containers:[],smart_enabled:$enabled}' > "$tmp"
 fi
 valid_config "$tmp" || return 1
 if [[ -f $CONFIG ]]; then
  backup=$(mktemp "$CONFIG_DIR/.watchman-backup.XXXXXXXX") || return 1
  cp -- "$CONFIG" "$backup" || { rm -f -- "$backup"; return 1; }
  chmod 600 "$backup"
  mv -f -- "$backup" "$CONFIG.bak" || return 1
 fi
 chmod 600 "$tmp"
 mv -f -- "$tmp" "$CONFIG"
 PENDING_CONFIG=''
 echo "Saved SMART monitoring = $enabled (read-only, hourly)."
 reload_note
}
set_webhook() {
 local url tmp answer
 echo "Discord: Server Settings > Integrations > Webhooks > New Webhook > Copy Webhook URL."
 printf 'Paste the webhook URL (hidden; Enter alone cancels): '
 read -rs url || return 0; echo
 [[ -n "$url" ]] || { echo "Canceled."; return 0; }
 [[ "$url" =~ ^https://discord\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$ ]] || { echo "That is not a Discord webhook URL; nothing saved." >&2; return 0; }
 mkdir -p "$CONFIG_DIR"
 tmp=$(mktemp "$CONFIG_DIR/.webhook.XXXXXXXX") || return 1
 PENDING_CONFIG="$tmp"
 printf '%s\n' "$url" > "$tmp"; chmod 600 "$tmp"
 mv -f -- "$tmp" "$WEBHOOK_FILE"; PENDING_CONFIG=''
 echo "Webhook saved (private file: $WEBHOOK_FILE)."
 reload_note
 printf 'Send a test message now? [Y/n] '
 read -r answer || return 0
 [[ "$answer" == [nN] ]] || bash "$ENGINE" --test-notify || echo "Test message failed; check the URL and network." >&2
}
set_ollama_model() {
 local model answer tmp backup
 printf 'Ollama model name (example llama3.2:1b, blank cancels): '
 read -r model || return 0
 [[ -n "$model" ]] || { echo "Canceled."; return 0; }
 if [[ ! "$model" =~ ^[A-Za-z0-9_.:/-]{1,100}$ ]]; then
  echo "Invalid model name; only letters, numbers, _, ., :, /, - allowed." >&2
  return 1
 fi
 if [[ -f "$CONFIG" ]]; then
  valid_config "$CONFIG" || { echo "Existing config invalid; refusing overwrite." >&2; return 1; }
 fi
 printf 'Save model %s? [y/N] ' "$model"
 read -r answer || return 0
 [[ "$answer" == [yY] ]] || { echo "Discarded."; return 0; }
 mkdir -p "$CONFIG_DIR"
 tmp=$(mktemp "$CONFIG_DIR/.watchman.XXXXXXXX") || return 1
 PENDING_CONFIG="$tmp"
 if [[ -f "$CONFIG" ]]; then
  jq --arg model "$model" '.ollama_model=$model' "$CONFIG" > "$tmp"
 else
  jq -n --arg model "$model" '{version:"0.4.2",disks:[],containers:[],ollama_model:$model}' > "$tmp"
 fi
 valid_config "$tmp" || return 1
 if [[ -e "$CONFIG" ]]; then
  backup=$(mktemp "$CONFIG_DIR/.watchman-backup.XXXXXXXX") || return 1
  cp -- "$CONFIG" "$backup" || { rm -f -- "$backup"; return 1; }
  chmod 600 "$backup"
  mv -f -- "$backup" "$CONFIG.bak" || return 1
 fi
 chmod 600 "$tmp"
 mv -f -- "$tmp" "$CONFIG"
 PENDING_CONFIG=''
 echo "Saved Ollama model: $model"
 reload_note
}
menu() {
 while true; do
  banner
  printf '\n[1] Detect disks and containers\n[2] View report\n[3] Help\n[4] Restore previous configuration\n[5] Set telemetry source\n[6] Set Ollama model\n[7] Connect Discord (webhook)\n[8] Send test message\n[9] Toggle standby-safe SMART monitoring\n[0] Exit\nChoice: '
  read -r choice || return 0
  case "$choice" in
   1) discover ;;
   2) load_config; bash "$ENGINE" --report ;;
   3) usage ;;
   4) restore_backup ;;
   5) set_metrics_mode ;;
   6) set_ollama_model ;;
   7) set_webhook ;;
   8) bash "$ENGINE" --test-notify || true ;;
   9) set_smart_enabled ;;
   0) return 0 ;;
   *) echo "Unknown selection" ;;
  esac
 done
}
case "${1:-}" in
 --help|-h) usage ;;
 --check-config)
  # Used by the supervisor before reloading: exit 0 only if the saved configuration is valid.
  load_config && echo "Configuration valid." ;;
 --report|--send-report|--ai|--once|--watch|--test-notify)
  [[ $# -eq 1 ]] || { usage >&2; exit 2; }
  load_config
  exec bash "$ENGINE" "$1" ;;
 "")
  [[ $# -eq 0 ]] || { usage >&2; exit 2; }
  if [[ ! -t 0 || ! -t 1 ]]; then load_config; exec bash "$ENGINE" --report; fi
  menu ;;
 *) usage >&2; exit 2 ;;
esac
