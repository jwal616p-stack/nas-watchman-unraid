#!/bin/bash
# NAS Watchman control script: install, upgrade, rollback, uninstall, start/stop/status, setup.
#   watchman install --from DIR | setup | start | stop | restart | status | report
#   watchman rollback | enable | disable | uninstall [--purge] [--yes] | version
# Layout (all separate from the v0.3 "nas-watchman" folders, which are never touched):
#   /boot/config/plugins/watchman/  releases/<id>/, current, previous, config/, boot.sh   (flash, persistent)
#   /usr/local/emhttp/plugins/watchman/  runtime copy + Unraid event hooks               (RAM, rebuilt at boot)
#   /mnt/user/appdata/watchman/  alert history (created only once the array and appdata are available)
set -uo pipefail
umask 077
export LC_ALL=C
ROOT=${WATCHMAN_ROOT:-}   # test prefix only; empty on a real server
[[ -z $ROOT || ( $ROOT == /* && $ROOT != / ) ]] || { echo "watchman: bad WATCHMAN_ROOT" >&2; exit 2; }
NAME=watchman
FLASH=$ROOT/boot/config/plugins/$NAME
RELEASES=$FLASH/releases
CONFIG_DIR=$FLASH/config
GO=$ROOT/boot/config/go
GO_LINE="bash $FLASH/boot.sh # NAS Watchman autostart (remove with: watchman uninstall)"
RT=$ROOT/usr/local/emhttp/plugins/$NAME
BIN=$ROOT/usr/local/bin/watchman
RUN=$ROOT/var/run/$NAME
LOG=$ROOT/var/log/$NAME.log
VAR_INI=$ROOT/var/local/emhttp/var.ini
USER_MNT=$ROOT/mnt/user
STATE_DIR=$USER_MNT/appdata/$NAME
POLL=${WATCHMAN_POLL:-5}
FILES=(watchman.sh watchman_engine.sh watchman_local_metrics.sh watchman_smart.sh watchmanctl.sh VERSION)

say() { printf '%s\n' "$*"; }
die() { printf 'watchman: %s\n' "$*" >&2; exit 1; }
log() { mkdir -p "${LOG%/*}" 2>/dev/null; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; }
read_ptr() { local v=''; [[ -f $FLASH/$1 ]] && read -r v < "$FLASH/$1"; [[ -n $v && $v != */* && -d $RELEASES/$v ]] && printf '%s' "$v"; }
write_ptr() { local tmp; tmp=$(mktemp "$FLASH/.$1.XXXXXX") || return 1; printf '%s\n' "$2" > "$tmp" && mv -f -- "$tmp" "$FLASH/$1"; }
running() { [[ -e $RUN/lock ]] || return 1; ! flock -n "$RUN/lock" true 2>/dev/null; }
sv_pid() { local p=''; [[ -f $RUN/pid ]] && read -r p < "$RUN/pid"; [[ $p =~ ^[0-9]+$ ]] && printf '%s' "$p"; }

# Array started, user shares really mounted, appdata present. Never creates anything.
storage_ready() {
  grep -qx 'mdState="STARTED"' "$VAR_INI" 2>/dev/null || return 1
  if [[ -z $ROOT ]]; then mountpoint -q /mnt/user || return 1
  else [[ -e $ROOT/.test-mounted ]] || return 1; fi
  [[ -d $USER_MNT/appdata ]]
}
engine_env() {
  export WATCHMAN_CONFIG_DIR=$CONFIG_DIR WATCHMAN_WEBHOOK_FILE=$CONFIG_DIR/discord-webhook WATCHMAN_STATE_DIR=$STATE_DIR \
         WATCHMAN_DISKS_INI=$ROOT/var/local/emhttp/disks.ini WATCHMAN_VAR_INI=$VAR_INI WATCHMAN_INSTALLED=1
  [[ -z $ROOT ]] || export WATCHMAN_SYSLOG=$ROOT/var/log/syslog
}
# A pinned newer controller keeps rollback/undo and boot functional even when
# the monitored engine was rolled back to an older release of watchman.sh.
controller_path() {
  if [[ -s $FLASH/controller.sh ]]; then printf '%s' "$FLASH/controller.sh"
  else printf '%s' "$RT/watchmanctl.sh"; fi
}
wrapper() { printf '#!/bin/bash\n%sexec bash %q %s\n' "${ROOT:+WATCHMAN_ROOT=$(printf %q "$ROOT") }" "$(controller_path)" "$1"; }

# ---------- runtime (RAM) ----------
deploy_runtime() {   # stage complete RAM runtime, swapping without deleting the last good copy
  local rel=$RELEASES/$1 tmp backup='' f
  mkdir -p "${RT%/*}" "${BIN%/*}" || return 1
  tmp=$(mktemp -d "${RT%/*}/.$NAME.XXXXXX") || return 1
  # v0.4.4 and earlier legitimately predate the SMART collector. Only those
  # verified older releases may omit it; never silently accept a damaged new
  # release missing a required file.
  local release_version=''
  [[ -f $rel/VERSION ]] && IFS= read -r release_version < "$rel/VERSION"
  for f in "${FILES[@]}"; do
    if [[ $f == watchman_smart.sh && ! -f $rel/$f &&
          $release_version =~ ^0\.4\.[0-4]([.-][A-Za-z0-9.-]+)?$ ]]; then
      continue
    fi
    [[ -f $rel/$f && ! -L $rel/$f ]] && cp -- "$rel/$f" "$tmp/$f" ||
      { rm -rf -- "$tmp"; return 1; }
  done
  printf '%s\n' "$1" > "$tmp/RELEASE" || { rm -rf -- "$tmp"; return 1; }
  mkdir -p "$tmp/event" || { rm -rf -- "$tmp"; return 1; }
  # emhttp waits for event scripts: start returns at once; hold stops the engine before shares unmount.
  wrapper 'start --event >/dev/null 2>&1 &' > "$tmp/event/disks_mounted"
  wrapper 'start --event >/dev/null 2>&1 &' > "$tmp/event/started"
  wrapper 'hold >/dev/null 2>&1' > "$tmp/event/stopping"
  chmod 755 "$tmp" "$tmp/event" "$tmp"/event/* || { rm -rf -- "$tmp"; return 1; }
  if [[ -e $RT ]]; then
    backup=$(mktemp -d "${RT%/*}/.$NAME.previous.XXXXXX") || { rm -rf -- "$tmp"; return 1; }
    rmdir -- "$backup" || { rm -rf -- "$tmp"; return 1; }
    mv -- "$RT" "$backup" || { rm -rf -- "$tmp"; return 1; }
  fi
  if ! mv -- "$tmp" "$RT"; then
    [[ -z $backup ]] || mv -- "$backup" "$RT"
    rm -rf -- "$tmp"
    return 1
  fi
  if ! { wrapper '"$@"' > "$BIN.tmp" && chmod 755 "$BIN.tmp" && mv -f -- "$BIN.tmp" "$BIN"; }; then
    rm -f -- "$BIN.tmp"
    rm -rf -- "$RT"
    [[ -z $backup ]] || mv -- "$backup" "$RT"
    return 1
  fi
  [[ -z $backup ]] || rm -rf -- "$backup"
}

# ---------- supervisor ----------
cfg_sig() { cksum < "$CONFIG_DIR/watchman.json" 2>/dev/null || echo none; }
cmd_run() {
  local child=0 hold=0 hold_since=0 stopping=0 rc child_sig='' bad_sig='' sig
  mkdir -p "$RUN" || exit 1
  exec 8>"$RUN/lock"
  flock -n 8 || { log "supervisor already running"; exit 0; }
  printf '%s\n' "$$" > "$RUN/pid"
  cd / || exit 1
  trap 'stopping=1' TERM INT
  trap 'hold=1; hold_since=$SECONDS' USR1
  status() { printf '%s\n' "$1" > "$RUN/status"; }
  stop_child() {
    (( child )) || return 0
    kill -TERM "$child" 2>/dev/null
    # jobs -pr reports *running* child jobs. kill -0 can still succeed for an
    # exited-but-unreaped child and incorrectly burn the entire timeout.
    for _ in $(seq 120); do
      jobs -pr | grep -qx -- "$child" || break
      sleep 0.25
    done
    if jobs -pr | grep -qx -- "$child"; then
      log "engine did not exit after TERM; forcing stop"
      kill -KILL "$child" 2>/dev/null
    fi
    wait "$child" 2>/dev/null
    child=0; rm -f -- "$RUN/engine.pid"; log "engine stopped"
  }
  log "supervisor started ($(read_ptr current))"
  while (( !stopping )); do
    if (( hold )); then
      stop_child; status "paused: array stopping"
      if ! storage_ready || (( SECONDS - hold_since > 600 )); then hold=0; fi
    elif storage_ready; then
      if (( child )) && ! kill -0 "$child" 2>/dev/null; then
        wait "$child"; rc=$?; child=0; rm -f -- "$RUN/engine.pid"
        log "engine exited (code $rc); restarting in 30 s"; status "engine exited (code $rc); restarting"
        # Interruptible backoff: failed engines must not delay a rollback or
        # a requested stop for another 30 seconds.
        for (( backoff=0; backoff<30 && !stopping; backoff+=5 )); do
          sleep 5 8>&- & wait $! 2>/dev/null || :
        done
        continue
      fi
      # Saved setup changes reload the engine (never Docker or the array). Invalid config: keep running.
      if (( child )) && sig=$(cfg_sig) && [[ $sig != "$child_sig" && $sig != "$bad_sig" ]]; then
        if ( exec 8>&-; engine_env; bash "$RT/watchman.sh" --check-config ) >/dev/null 2>&1; then
          log "configuration changed; reloading engine"; stop_child; bad_sig=''
        else
          log "configuration change is invalid; engine keeps the previous settings"; bad_sig=$sig
        fi
      fi
      if (( !child )); then
        mkdir -p "$STATE_DIR" || { status "cannot create $STATE_DIR"; sleep "$POLL" 8>&- & wait $!; continue; }
        # fd 8 (the lock) is closed for the engine so neither it nor its leftovers can hold the lock.
        ( exec 8>&-; engine_env; exec bash "$RT/watchman.sh" --watch ) >> "$LOG" 2>&1 < /dev/null &
        child=$!; child_sig=$(cfg_sig); printf '%s\n' "$child" > "$RUN/engine.pid"; log "engine started (pid $child)"
      fi
      status "running"
    else
      (( child )) && { log "array or appdata unavailable"; stop_child; }
      status "waiting for array start and /mnt/user/appdata"
    fi
    sleep "$POLL" 8>&- & wait $!
  done
  stop_child; rm -f -- "$RUN/pid" "$RUN/status"; log "supervisor stopped"
}
cmd_start() {
  [[ ${1:-} == --event && -f $FLASH/disabled ]] && exit 0
  [[ -n $(read_ptr current) ]] || { say 'watchman: not installed' >&2; return 1; }
  [[ -f $RT/watchmanctl.sh ]] || deploy_runtime "$(read_ptr current)" || { say 'watchman: runtime deploy failed' >&2; return 1; }
  running && { say "Watchman already running."; return 0; }
  mkdir -p "$RUN" "${LOG%/*}"
  [[ ! -f $LOG ]] || (( $(stat -c %s "$LOG") < 524288 )) || mv -f -- "$LOG" "$LOG.1"
  setsid bash "$(controller_path)" run >> "$LOG" 2>&1 < /dev/null &
  for _ in $(seq 40); do running && break; sleep 0.1; done
  if running; then say "Watchman started."
  else say "watchman: supervisor did not start; see $LOG" >&2; return 1; fi
}
# A supervisor lock does NOT prove its worker is alive. This is used after
# rollback and after an install that restored a saved SMART setting; do not
# consume the archived configuration until the engine survives startup.
engine_stable_after_start() {
  local pid
  storage_ready || return 0  # array stopped: a waiting supervisor is correct
  for _ in $(seq 40); do
    pid=$(cat "$RUN/engine.pid" 2>/dev/null || :)
    if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null &&
       [[ $(cat "$RUN/status" 2>/dev/null) == running ]]; then
      sleep 0.3
      if kill -0 "$pid" 2>/dev/null &&
         [[ $(cat "$RUN/status" 2>/dev/null) == running ]]; then return 0; fi
    fi
    sleep 0.2
  done
  return 1
}
cmd_stop() {
  local p; p=$(sv_pid)
  running || { rm -f -- "$RUN/pid" "$RUN/status" "$RUN/engine.pid"; say "Watchman is not running."; return 0; }
  [[ -n $p ]] && kill -TERM "$p" 2>/dev/null
  for _ in $(seq 140); do running || break; sleep 0.25; done
  if running && [[ -n $p ]]; then kill -KILL -- "-$p" 2>/dev/null; sleep 0.5; fi
  running && { say "watchman: could not stop supervisor (pid ${p:-?})" >&2; return 1; }
  say "Watchman stopped."
}
cmd_hold() {   # Unraid "stopping" event: engine must release /mnt/user before shares unmount
  local p; p=$(sv_pid); running && [[ -n $p ]] || return 0
  kill -USR1 "$p" 2>/dev/null
  for _ in $(seq 140); do [[ -e $RUN/engine.pid ]] || return 0; sleep 0.25; done
}
cmd_status() {
  local cur prev st="not running"
  cur=$(read_ptr current); prev=$(read_ptr previous)
  [[ -n $cur ]] || { say "Watchman: not installed."; return 3; }
  running && st=$(cat "$RUN/status" 2>/dev/null || echo starting)
  say "Watchman $cur"
  say "  status:     $st"
  say "  autostart:  $(grep -qxF "$GO_LINE" "$GO" 2>/dev/null && { [[ -f $FLASH/disabled ]] && echo disabled || echo enabled; } || echo 'missing (run install again)')"
  say "  rollback:   ${prev:-none available}"
  say "  storage:    $(storage_ready && echo ready || echo 'not ready (array stopped or /mnt/user/appdata missing)')"
  say "  config:     $([[ -f $CONFIG_DIR/watchman.json ]] && echo "$CONFIG_DIR/watchman.json" || echo 'not set up yet (run: watchman setup)')"
  say "  discord:    $([[ -s $CONFIG_DIR/discord-webhook ]] && echo configured || echo 'not configured (run: watchman setup)')"
  [[ $(cat "$RT/RELEASE" 2>/dev/null) == "$cur" ]] || say "  note: running code differs from installed release; run: watchman restart"
  ps -eo args 2>/dev/null | grep -q '[/]boot/config/plugins/nas-watchman/watchman.sh' && say "  note: legacy v0.3 is also running; you may get duplicate alerts"
  [[ $st == "not running" ]] && return 3 || return 0
}

# ---------- install / upgrade / rollback / uninstall ----------
add_go_line() {
  [[ -f $GO ]] || die "$GO not found"
  grep -qxF "$GO_LINE" "$GO" && return 0
  [[ -f $GO.watchman-backup ]] || cp -p -- "$GO" "$GO.watchman-backup" || return 1
  local tmp; tmp=$(mktemp "$GO.XXXXXX") || return 1
  { cat -- "$GO"; [[ -z $(tail -c 1 -- "$GO") ]] || echo; printf '%s\n' "$GO_LINE"; } > "$tmp" &&
    chmod --reference="$GO" "$tmp" && mv -f -- "$tmp" "$GO" || { rm -f -- "$tmp"; return 1; }
}
remove_go_line() {
  [[ -f $GO ]] && grep -qxF "$GO_LINE" "$GO" || return 0
  local tmp; tmp=$(mktemp "$GO.XXXXXX") || return 1
  grep -vxF "$GO_LINE" "$GO" > "$tmp" &&
    chmod --reference="$GO" "$tmp" && mv -f -- "$tmp" "$GO" || { rm -f -- "$tmp"; return 1; }
}
write_boot_sh() {
  local tmp; tmp=$(mktemp "$FLASH/.boot.XXXXXX") || return 1
  cat > "$tmp" <<EOF
#!/bin/bash
# NAS Watchman boot hook, run from /boot/config/go. Copies the current release into RAM and starts
# the supervisor, which waits for the array and /mnt/user/appdata before doing anything.
${ROOT:+export WATCHMAN_ROOT=$(printf %q "$ROOT")}
rel=\$(head -n 1 $(printf %q "$FLASH/current") 2>/dev/null) || exit 0
case "\$rel" in ''|*/*) exit 0;; esac
controller=$(printf %q "$FLASH/controller.sh")
[[ -f "\$controller" ]] || controller=$(printf %q "$RELEASES")/"\$rel"/watchmanctl.sh
bash "\$controller" boot >> $(printf %q "$LOG") 2>&1 < /dev/null &
EOF
  mv -f -- "$tmp" "$FLASH/boot.sh"
}
cmd_boot() { local cur; cur=$(read_ptr current) || exit 0; deploy_runtime "$cur" && [[ ! -f $FLASH/disabled ]] && cmd_start; }
preflight() {   # $1 = source dir. Nothing is changed if this fails.
  local src=$1 f
  [[ -z $ROOT ]] && { [[ $EUID -eq 0 ]] || die "run as root"; [[ -f /etc/unraid-version ]] || die "not an Unraid server"; }
  for f in "${FILES[@]}"; do [[ -f $src/$f ]] || die "missing $f in $src"; done
  for f in watchman.sh watchman_engine.sh watchman_local_metrics.sh watchman_smart.sh watchmanctl.sh; do bash -n "$src/$f" || die "syntax error in $f"; done
  for f in jq curl flock timeout awk setsid; do command -v "$f" >/dev/null || die "missing dependency: $f"; done
  [[ -n $ROOT ]] || command -v mountpoint >/dev/null || die "missing dependency: mountpoint"
  grep -qE '^[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.-]*$' "$src/VERSION" || die "bad VERSION file"
  bash "$src/watchman_local_metrics.sh" | jq -e '.source=="watchman-local-readonly"' >/dev/null || die "telemetry self-test failed"
}
prune_releases() {   # keep current, previous and the newest other release
  local cur prev kept=0 d
  cur=$(read_ptr current); prev=$(read_ptr previous)
  while IFS= read -r d; do
    [[ $d == "$cur" || $d == "$prev" ]] && continue
    (( kept++ < 1 )) && continue
    rm -rf -- "${RELEASES:?}/$d"
  done < <(ls -1t "$RELEASES" 2>/dev/null | grep -v '^\.')
}
# The pre-SMART rollback archive stores the complete newer configuration.
# Merge only its SMART toggle into the CURRENT (possibly edited) old config.
# Never restore the whole old snapshot over changed disk/alert settings.
# A damaged or partial archive is not silently discarded.
rollback_archive_state() {
  local backup=$CONFIG_DIR/watchman.json.pre-smart-rollback
  local hash=$CONFIG_DIR/watchman.json.pre-smart-rollback.cksum
  if [[ ! -e $backup && ! -e $hash ]]; then return 1; fi
  [[ -f $backup && ! -L $backup && -f $hash && ! -L $hash ]] ||
    { say 'Incomplete rollback config archive; inspect both saved files before continuing.' >&2; return 2; }
  jq -e 'type=="object" and has("smart_enabled") and (.smart_enabled|type)=="boolean"' "$backup" >/dev/null 2>&1 ||
    { say 'Invalid saved SMART preference; retaining rollback config archive.' >&2; return 2; }
  [[ $(cat "$hash") =~ ^[0-9]+[[:space:]][0-9]+$ ]] ||
    { say 'Invalid rollback config fingerprint; retaining archive.' >&2; return 2; }
  return 0
}
merge_saved_smart() {
  local current=$1 saved=$2 output=$3
  # Explicitly reject a conflict rather than overwriting an intentional
  # edit that already introduced a SMART setting.
  jq -es '
    .[0] as $current | .[1] as $saved |
    if ($current|type)!="object" or ($saved|type)!="object" or
       ($current|has("smart_enabled")) or
       (($saved|has("smart_enabled"))|not) or
       ($saved.smart_enabled|type)!="boolean" then error("cannot safely merge SMART preference")
    else $current + {smart_enabled:$saved.smart_enabled} end' \
    "$current" "$saved" > "$output" || return 1
  chmod --reference="$current" "$output"
}
# Config validation with a specific target release, without changing the live
# Watchman configuration, disks, or the existing supervisor.
script_accepts_config() {
  local script=$1 candidate=$2 tempdir rc
  [[ -f $candidate && -f $script ]] || return 1
  tempdir=$(mktemp -d "$CONFIG_DIR/.config-check.XXXXXX") || return 1
  cp -- "$candidate" "$tempdir/watchman.json" || { rm -rf -- "$tempdir"; return 1; }
  ( export WATCHMAN_CONFIG_DIR=$tempdir WATCHMAN_WEBHOOK_FILE=$CONFIG_DIR/discord-webhook
    bash "$script" --check-config ) >/dev/null 2>&1
  rc=$?
  rm -rf -- "$tempdir"
  return "$rc"
}
release_accepts_config() { script_accepts_config "$RELEASES/$1/watchman.sh" "$2"; }
# Install/rollback change the config only through same-filesystem atomic rename.
# On failure the last known good file is never partly overwritten.
activate_config() {
  local source=$1 target=$CONFIG_DIR/watchman.json staged
  staged=$(mktemp "$CONFIG_DIR/.config-active.XXXXXX") || return 1
  cp -p -- "$source" "$staged" && mv -f -- "$staged" "$target" ||
    { rm -f -- "$staged"; return 1; }
}
cmd_install() {
  local src='' old prev id stage was_running=0 go_added=0 f
  local config=$CONFIG_DIR/watchman.json backup=$CONFIG_DIR/watchman.json.pre-smart-rollback
  local hash=$CONFIG_DIR/watchman.json.pre-smart-rollback.cksum
  local config_before='' config_candidate='' config_merged=0 config_archive=0
  [[ ${1:-} == --from && -n ${2:-} ]] && src=$(cd -- "$2" && pwd) || die "usage: watchman install --from DIR"
  preflight "$src"
  [[ -f $GO ]] || die "$GO not found; is this Unraid?"
  old=$(read_ptr current); prev=$(read_ptr previous)
  mkdir -p "$RELEASES" "$CONFIG_DIR" || die "cannot create $FLASH"
  # A reinstall after a downgrade is another route forward. The old config
  # may have intentional edits, so NEVER install with the SMART toggle missing.
  # Stage and validate a narrow merge before changing the live installation.
  local archive_rc=0
  rollback_archive_state || archive_rc=$?
  (( archive_rc <= 1 )) || die 'cannot install while rollback configuration archive is incomplete or invalid'
  if (( archive_rc == 0 )); then
    [[ -f $config && ! -L $config ]] || die 'missing active rollback configuration; cannot safely merge'
    config_before=$(mktemp "$CONFIG_DIR/.install-original.XXXXXX") || die 'cannot stage active configuration'
    config_candidate=$(mktemp "$CONFIG_DIR/.install-merged.XXXXXX") || die 'cannot stage merged configuration'
    trap '[[ -z ${config_before:-} ]] || rm -f -- "$config_before"; [[ -z ${config_candidate:-} ]] || rm -f -- "$config_candidate"' EXIT
    cp -p -- "$config" "$config_before" || die 'cannot preserve active rollback configuration'
    merge_saved_smart "$config" "$backup" "$config_candidate" || die 'saved SMART preference conflicts with current config; unchanged'
    script_accepts_config "$src/watchman.sh" "$config_candidate" || die 'new release rejects merged configuration; installation left unchanged'
    config_archive=1
  fi
  for f in $(ls -1A "$RELEASES" | grep '^\.staging\.'); do rm -rf -- "${RELEASES:?}/$f"; done   # leftovers of interrupted installs
  id="$(cat "$src/VERSION")-$(date -u +%Y%m%dT%H%M%SZ)"
  [[ ! -e $RELEASES/$id ]] || id="$id-$$"
  stage=$(mktemp -d "$RELEASES/.staging.XXXXXX") || die "cannot stage release"
  trap 'rm -rf -- "$stage"; exit 130' INT TERM
  for f in "${FILES[@]}"; do cp -- "$src/$f" "$stage/$f" && cmp -s -- "$src/$f" "$stage/$f" || { rm -rf -- "$stage"; die "copy of $f failed or did not verify"; }; done
  mv -- "$stage" "$RELEASES/$id" || { rm -rf -- "$stage"; die "could not finalize release"; }
  trap - INT TERM
  # A failed activation must restore both release pointers, the prior runtime and
  # a newly added go line. Leave the release staged for inspection and retry.
  restore_previous_ptr() {
    if [[ -n $prev ]]; then write_ptr previous "$prev"; else rm -f -- "$FLASH/previous"; fi
  }
  activation_failed() {
    local reason=$1 ok=1
    # The failed release may already have started a live supervisor. Stop it
    # before replacing its runtime, config and pointers. Otherwise the old
    # worker never actually restarts, despite a success-looking supervisor lock.
    if running; then cmd_stop >/dev/null || ok=0; fi
    # Restore the exact active old-version configuration BEFORE restarting its
    # engine. An attempted upgrade must never strand it with a new-only key.
    if (( config_merged )); then activate_config "$config_before" || ok=0; fi
    if [[ -n $old ]]; then write_ptr current "$old" || ok=0
    else rm -f -- "$FLASH/current" || ok=0; fi
    restore_previous_ptr || ok=0
    if (( go_added )); then remove_go_line || ok=0; fi
    if [[ -n $old ]]; then
      deploy_runtime "$old" || ok=0
      if (( was_running )); then cmd_start >/dev/null || ok=0; fi
    else
      # Failed first install: no release should be selected or running.
      rm -rf -- "$RT" "$BIN" || ok=0
    fi
    (( ok )) || say 'WARNING: automatic recovery was incomplete; inspect watchman status before reboot.' >&2
    die "$reason (old release restored where possible)"
  }
  write_boot_sh || die "could not write boot.sh"
  # Update the autostart script *before* either release pointer. If this fails,
  # the old current/previous pointers and running engine are left untouched.
  grep -qxF "$GO_LINE" "$GO" || go_added=1
  add_go_line || die "could not add autostart line to $GO"
  if [[ -n $old ]]; then write_ptr previous "$old" || activation_failed 'could not write previous release pointer'; fi
  write_ptr current "$id" || activation_failed 'could not record current release'
  if running; then
    was_running=1
    cmd_stop >/dev/null || activation_failed 'could not stop the previous supervisor'
  fi
  if (( config_archive )); then
    config_merged=1
    activate_config "$config_candidate" || activation_failed 'could not safely activate merged configuration'
  fi
  deploy_runtime "$id" || activation_failed 'runtime deployment failed'
  if [[ ! -f $FLASH/disabled ]]; then
    cmd_start >/dev/null || activation_failed 'new supervisor failed to start'
    if (( config_archive )); then
      engine_stable_after_start || activation_failed 'new engine did not stay running; saved SMART preference retained'
    fi
  fi
  if [[ -s $FLASH/controller.sh ]]; then
    local pinned_tmp=''
    pinned_tmp=$(mktemp "$FLASH/.controller.XXXXXX")
    if [[ -n $pinned_tmp ]] && cp -p -- "$RELEASES/$id/watchmanctl.sh" "$pinned_tmp" &&
       mv -f -- "$pinned_tmp" "$FLASH/controller.sh"; then :
    else
      [[ -z $pinned_tmp ]] || rm -f -- "$pinned_tmp"
      say 'WARNING: pinned controller was not refreshed.' >&2
    fi
  fi
  if (( config_archive )); then
    if rm -f -- "$backup" "$hash"; then
      say 'Preserved edited legacy settings and restored the saved SMART preference; rollback archive cleared.'
    else
      say "WARNING: the merged config is active but rollback archive cleanup failed; inspect $backup and $hash." >&2
    fi
  fi
  prune_releases
  say "Installed Watchman $id${old:+ (previous: $old, use 'watchman rollback' to return to it)}."
  say "Config and alert history were kept. v0.3 files were not touched."
  [[ -f $CONFIG_DIR/watchman.json && -s $CONFIG_DIR/discord-webhook ]] || say "Next: run 'watchman setup' to choose disks/containers and connect Discord."
}
cmd_rollback() {
  local cur prev was_running=0 config_action='' candidate='' config_before='' target_version=''
  local config=$CONFIG_DIR/watchman.json backup=$CONFIG_DIR/watchman.json.pre-smart-rollback
  local hash=$CONFIG_DIR/watchman.json.pre-smart-rollback.cksum
  local pinned_created=0
  cur=$(read_ptr current); prev=$(read_ptr previous)
  [[ -n $cur && -n $prev ]] || die "no previous release to roll back to"
  [[ -f $RELEASES/$prev/VERSION ]] && read -r target_version < "$RELEASES/$prev/VERSION"
  # No scratch copies of configuration should survive a failed preflight.
  trap '[[ -z ${config_before:-} ]] || rm -f -- "$config_before"; [[ -z ${candidate:-} || $candidate == "$backup" ]] || rm -f -- "$candidate"' EXIT
  # Work out compatibility BEFORE stopping a healthy supervisor. Keep a copy of
  # the exact current config for restoring on any failure, including start.
  if [[ -f $config ]]; then
    config_before=$(mktemp "$CONFIG_DIR/.rollback-original.XXXXXX") || die 'could not stage rollback config'
    cp -p -- "$config" "$config_before" || die 'could not preserve rollback config'
    local archive_rc=0
    rollback_archive_state || archive_rc=$?
    (( archive_rc <= 1 )) || die 'rollback archive is incomplete or invalid; leaving current release unchanged'
    if (( archive_rc == 0 )); then
      candidate=$(mktemp "$CONFIG_DIR/.rollback-merged.XXXXXX") || die 'could not stage merged rollback config'
      merge_saved_smart "$config" "$backup" "$candidate" || die 'saved SMART preference conflicts with edited legacy configuration'
      if release_accepts_config "$prev" "$candidate"; then
        # The rollback target understands the restored key. Carry across every
        # edit made under the old version; bring forward only smart_enabled.
        config_action=restore
      elif release_accepts_config "$prev" "$config"; then
        # Moving between older releases: leave the archive intact until a
        # compatible newer release is installed or restored.
        config_action=''
      else
        die 'target release rejects edited config and safe SMART merge'
      fi
    elif ! release_accepts_config "$prev" "$config"; then
      [[ -f $RELEASES/$prev/VERSION ]] && read -r target_version < "$RELEASES/$prev/VERSION"
      # Only strip the newly introduced SMART toggle on a pre-SMART target;
      # never broadly discard unrecognized settings or invent defaults.
      [[ $target_version =~ ^0\.4\.[0-4]([.-][A-Za-z0-9.-]+)?$ ]] || die 'rollback target rejects current configuration'
      candidate=$(mktemp "$CONFIG_DIR/.rollback-compatible.XXXXXX") || die 'could not stage compatible config'
      jq -e 'type=="object" and has("smart_enabled")' "$config" >/dev/null 2>&1 || die 'rollback target rejects config (not a SMART-toggle-only change)'
      jq 'del(.smart_enabled)' "$config" > "$candidate" || die 'cannot build target-compatible config'
      chmod --reference="$config" "$candidate" || die 'cannot preserve config permissions'
      release_accepts_config "$prev" "$candidate" || die 'older release rejects safely adjusted config'
      config_action=downgrade
    fi
  fi
  # Rollback is a safety path: restore both pointers AND the live engine on any
  # activation failure. Never claim success just because pointers were changed.
  rollback_failed() {
    local reason=$1 ok=1
    cmd_stop >/dev/null || ok=0
    if [[ -n $config_before ]]; then
      activate_config "$config_before" || ok=0
    fi
    if [[ $config_action == downgrade ]]; then
      rm -f -- "$backup" "$hash" || ok=0
    fi
    if (( pinned_created )); then rm -f -- "$FLASH/controller.sh" || ok=0; fi
    write_ptr current "$cur" || ok=0
    write_ptr previous "$prev" || ok=0
    if [[ $(cat "$RT/RELEASE" 2>/dev/null) != "$cur" ]]; then
      deploy_runtime "$cur" || ok=0
    fi
    if (( was_running )); then cmd_start >/dev/null || ok=0; fi
    (( ok )) || say 'WARNING: rollback recovery incomplete; manual inspection required.' >&2
    die "$reason; original release restored where possible"
  }
  if running; then
    was_running=1
    cmd_stop >/dev/null || die 'could not stop supervisor for rollback'
  fi
  if [[ $config_action == downgrade ]]; then
    [[ ! -e $backup && ! -e $hash ]] || rollback_failed 'rollback archive already exists'
    cp -p -- "$config_before" "$backup" || rollback_failed 'cannot preserve SMART configuration'
    cksum < "$candidate" > "$hash" || rollback_failed 'cannot record rollback config fingerprint'
    activate_config "$candidate" || rollback_failed 'cannot activate older configuration'
  elif [[ $config_action == restore ]]; then
    activate_config "$candidate" || rollback_failed 'cannot activate merged newer configuration'
  fi
  # Older release scripts cannot reliably undo their own downgrade: retain
  # newer controller code across manual commands and the next simulated boot.
  if [[ $target_version =~ ^0\.4\.[0-4]([.-][A-Za-z0-9.-]+)?$ && ! -e $FLASH/controller.sh ]]; then
    cp -p -- "$RELEASES/$cur/watchmanctl.sh" "$FLASH/controller.sh" || rollback_failed 'cannot pin compatible rollback controller'
    pinned_created=1
  fi
  deploy_runtime "$prev" || rollback_failed 'could not deploy rollback target'
  write_ptr previous "$cur" || rollback_failed 'could not write previous pointer'
  write_ptr current "$prev" || rollback_failed 'could not switch current release'
  if [[ ! -f $FLASH/disabled ]]; then
    cmd_start >/dev/null || rollback_failed 'rollback supervisor failed to start'
    # Never report success on the supervisor lock alone.
    engine_stable_after_start || rollback_failed 'rollback engine did not stay running'
  fi
  if [[ $config_action == restore ]]; then
    if rm -f -- "$backup" "$hash"; then
      say 'Restored the saved SMART preference and kept all edits made while rolled back.'
    else
      say "WARNING: rollback archive cleanup failed; inspect $backup and $hash." >&2
    fi
  fi
  [[ -z $candidate || $config_action != downgrade ]] || rm -f -- "$candidate"
  [[ -z $config_before ]] || rm -f -- "$config_before"
  trap - EXIT
  say "Rolled back to $prev (was $cur). Run 'watchman rollback' again to undo."
}
cmd_uninstall() {
  local purge=0 yes=0 a
  for a in "$@"; do case $a in --purge) purge=1;; --yes) yes=1;; *) die "unknown option $a";; esac; done
  if (( !yes )); then
    printf 'Remove Watchman%s? [y/N] ' "$( (( purge )) && echo ' AND its config and alert history')"
    read -r a || exit 1; [[ $a == [yY] ]] || { say "Canceled."; return 0; }
  fi
  cmd_stop >/dev/null
  remove_go_line || die "could not edit $GO"
  rm -rf -- "$RT" "$RUN" "$BIN" "${RELEASES:?}" "$FLASH/boot.sh" "$FLASH/current" "$FLASH/previous" "$FLASH/disabled" "$FLASH/controller.sh"
  if (( purge )); then
    rm -rf -- "${CONFIG_DIR:?}"
    if storage_ready; then rm -rf -- "${STATE_DIR:?}"; else say "Array not started: $STATE_DIR left in place."; fi
  fi
  rmdir -- "$FLASH" 2>/dev/null
  say "Watchman removed.$( (( purge )) || echo " Config kept in $CONFIG_DIR and history in $STATE_DIR (use --purge to delete).")"
}
cmd_setup() { [[ -f $RT/watchman.sh ]] || die "not installed"; engine_env; exec bash "$RT/watchman.sh"; }
cmd_report() { [[ -f $RT/watchman.sh ]] || die "not installed"; engine_env; exec bash "$RT/watchman.sh" --report; }

case "${1:-status}" in
  install) shift; cmd_install "$@" ;;
  setup) cmd_setup ;;
  start) shift; cmd_start "$@" ;;
  stop) cmd_stop ;;
  restart) cmd_stop >/dev/null; deploy_runtime "$(read_ptr current)" && cmd_start ;;
  status) cmd_status ;;
  report) cmd_report ;;
  rollback) cmd_rollback ;;
  enable) rm -f -- "$FLASH/disabled"; cmd_start ;;
  disable) touch "$FLASH/disabled"; cmd_stop ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  version) read_ptr current; echo ;;
  run) cmd_run ;;
  hold) cmd_hold ;;
  boot) cmd_boot ;;
  -h|--help|help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command ${1}; try: watchman help" ;;
esac
