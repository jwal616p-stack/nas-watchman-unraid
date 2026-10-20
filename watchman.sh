#!/usr/bin/env bash
# NAS Watchman v0.4.2 isolated launcher prototype
set -euo pipefail
umask 077
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENGINE="$HERE/watchman_engine.sh"
CONFIG_DIR="${WATCHMAN_CONFIG_DIR:-/boot/config/plugins/nas-watchman}"
CONFIG="$CONFIG_DIR/watchman.json"
DISKS_INI="${WATCHMAN_DISKS_INI:-/var/local/emhttp/disks.ini}"
PENDING_CONFIG=''
cleanup_pending() {
 [[ -z "$PENDING_CONFIG" ]] || rm -f -- "$PENDING_CONFIG"
}
trap cleanup_pending EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
usage() {
cat <<'EOF'
NAS Watchman v0.4.2 (development)
Usage: watchman.sh [--help|--report|--send-report|--ai|--once|--watch]
No arguments with a terminal: setup menu.
No arguments without a terminal: read-only report.
Commands always bypass the wizard. No daemon starts during setup.
EOF
}
valid_config() {
 jq -e 'type=="object" and
 ((keys - ["version","disks","containers","gpu_warn","ram_warn","disk_temp_default","metrics_mode","ollama_model"])|length==0) and
 (.version=="0.4.2") and
 ((.metrics_mode // "sidecar") as $m | $m=="sidecar" or $m=="local") and
 ((.ollama_model // "llama3.2:1b")|type=="string" and length>=1 and length<=100 and test("^[A-Za-z0-9_.:/-]+$")) and
 (.disks|type=="array" and all(.[];type=="string" and length>0) and (unique|length)==length) and
 (.containers|type=="array" and all(.[];type=="string" and length>0) and (unique|length)==length) and
 ((.gpu_warn // 85)|type=="number" and .==floor and .>=0 and .<=100) and
 ((.ram_warn // 90)|type=="number" and .==floor and .>=0 and .<=100) and
 ((.disk_temp_default // 55)|type=="number" and .==floor and .>=1 and .<=120)' "$1" >/dev/null
}
load_config() {
 [[ -f "$CONFIG" ]] || return 0
 command -v jq >/dev/null || { echo "jq required to load configuration" >&2; return 1; }
 valid_config "$CONFIG" || { echo "Invalid configuration: $CONFIG; refusing to run" >&2; if [[ -f "$CONFIG.bak" ]] && valid_config "$CONFIG.bak"; then echo "Valid backup available: use interactive Restore Previous Configuration." >&2; else echo "No valid backup; manual recovery required." >&2; fi; return 1; }
 export WATCHMAN_DISKS WATCHMAN_CONTAINERS GPU_WARN RAM_WARN WATCHMAN_DISK_TEMP_DEFAULT WATCHMAN_METRICS_MODE WATCHMAN_OLLAMA_MODEL
 WATCHMAN_DISKS=$(jq -c '.disks' "$CONFIG")
 WATCHMAN_CONTAINERS=$(jq -c '.containers' "$CONFIG")
 GPU_WARN=$(jq -r '.gpu_warn // 85' "$CONFIG")
 RAM_WARN=$(jq -r '.ram_warn // 90' "$CONFIG")
 WATCHMAN_DISK_TEMP_DEFAULT=$(jq -r '.disk_temp_default // 55' "$CONFIG")
 WATCHMAN_METRICS_MODE=$(jq -r '.metrics_mode // "sidecar"' "$CONFIG")
 WATCHMAN_OLLAMA_MODEL=$(jq -r '.ollama_model // "llama3.2:1b"' "$CONFIG")
}
banner() {
 cat <<'EOF'
      / \__
     (    @\___   NAS WATCHMAN v0.4.2
     /         O  Chief Security Officer on Duty
    /   (_____/
   /_____/   U
EOF
}
discover() {
 local disks='[]' containers='[]' names disk_ok=1 docker_ok=1
 if [[ -r "$DISKS_INI" ]]; then
  names=$(awk -F= '/^\[disk[0-9]+\]/{gsub(/\[|\]/,"",$1);print $1}' "$DISKS_INI")
  if [[ -n "$names" ]]; then disks=$(printf '%s\n' "$names" | jq -R . | jq -sc 'unique'); fi
 else
  echo "Disk discovery unavailable (file unreadable)." >&2
  disk_ok=0
 fi
 if command -v docker >/dev/null; then
  names=$(docker ps -a --format '{{.Names}}' 2>/dev/null) || { echo "Docker discovery unavailable." >&2; docker_ok=0; names=''; }
  if [[ -n "$names" ]]; then containers=$(printf '%s\n' "$names" | jq -R . | jq -sc 'unique'); fi
 else
  echo "Docker discovery unavailable (Docker CLI missing)." >&2
  docker_ok=0
 fi
 printf 'Disks: %s\nContainers: %s\n' "$disks" "$containers"
 if (( !disk_ok || !docker_ok )); then
  echo "Discovery incomplete. Nothing saved; please resolve unavailable sources." >&2
  return 0
 fi
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
}
restore_backup() {
 local backup="$CONFIG.bak" tmp answer
 if [[ ! -f "$backup" ]]; then
  echo "No saved backup available."
  return 0
 fi
 valid_config "$backup" || { echo "Backup invalid; refusing to restore." >&2; return 1; }
 echo "Backup contents:"
 jq '{disks,containers,metrics_mode,ollama_model,gpu_warn,ram_warn,disk_temp_default}' "$backup"
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
}
set_metrics_mode() {
 local mode answer tmp backup
 echo "Telemetry source: [1] Sidecar HTTP API (default)  [2] Local read-only collector"
 printf 'Select [1/2] (other cancels): '
 read -r answer || return 0
 case "$answer" in
  1) mode=sidecar ;;
  2) mode=local ;;
  *) echo "Canceled."; return 0 ;;
 esac
 if [[ -f "$CONFIG" ]]; then
  valid_config "$CONFIG" || { echo "Existing config invalid; refusing overwrite." >&2; return 1; }
  printf 'Current mode: %s\n' "$(jq -r '.metrics_mode // "sidecar"' "$CONFIG")"
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
}
menu() {
 while true; do
  banner
  printf '\n[1] Detect disks and containers\n[2] View report\n[3] Help\n[4] Restore previous configuration\n[5] Set telemetry source\n[6] Set Ollama model\n[0] Exit\nChoice: '
  read -r choice || return 0
  case "$choice" in
   1) discover ;;
   2) load_config; bash "$ENGINE" --report ;;
   3) usage ;;
   4) restore_backup ;;
   5) set_metrics_mode ;;
   6) set_ollama_model ;;
   0) return 0 ;;
   *) echo "Unknown selection" ;;
  esac
 done
}
case "${1:-}" in
 --help|-h) usage ;;
 --report|--send-report|--ai|--once|--watch)
  [[ $# -eq 1 ]] || { usage >&2; exit 2; }
  load_config
  exec bash "$ENGINE" "$1" ;;
 "")
  [[ $# -eq 0 ]] || { usage >&2; exit 2; }
  if [[ ! -t 0 || ! -t 1 ]]; then load_config; exec bash "$ENGINE" --report; fi
  menu ;;
 *) usage >&2; exit 2 ;;
esac
