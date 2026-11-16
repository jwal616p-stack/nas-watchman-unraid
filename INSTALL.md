# Installing NAS Watchman v0.4.5-dev on Unraid

**Development preview:** review this branch and test it on a backup or noncritical machine before broader use. No Docker container or Python is needed on the Unraid server (Unraid 7 supplies Bash, jq and curl).

## Install
```bash
# on the Unraid server, as root, from the unpacked Watchman folder:
bash install.sh
watchman setup        # [1] detect disks + pick containers, [7] connect Discord + test message
watchman status
```
Watchman starts on its own after every boot, but only once the array is started and
`/mnt/user/appdata` is available. Until then `watchman status` says it is waiting.
Changes saved in `watchman setup` are picked up within a few seconds (only the monitoring engine
reloads; Docker and the array are never touched). An invalid manual edit is ignored and logged.

**Containers:** the picker preselects the containers set to *Autostart* in Unraid's Docker tab, since
those are meant to be running. Tick or untick by number; `q` cancels. Watchman alerts when a ticked
container is not running.

## Everyday commands
| Command | What it does |
|---|---|
| `watchman status` | version, running/waiting, autostart, rollback target, Discord configured |
| `watchman report` | print a one-off reading (changes nothing) |
| `watchman stop` / `start` / `restart` | stop or start now (autostart unchanged) |
| `watchman disable` / `enable` | turn autostart off/on (survives reboots) |
| `watchman setup` | change disks, containers, telemetry, Discord |

## Upgrade, rollback, uninstall
- **Upgrade:** unpack the new version and run `bash install.sh` again. Config and alert history are kept.
  The new version is fully staged and self-tested before it is switched in; if anything fails or the
  install is interrupted, the working version stays in place.
- **Rollback:** `watchman rollback` returns to the previous version (run it again to undo).
- **Uninstall:** `watchman uninstall` removes the program and the autostart line but keeps your config
  and alert history. `watchman uninstall --purge` deletes those too.

## What it changes on the server
- One line appended to `/boot/config/go` (original saved once as `/boot/config/go.watchman-backup`;
  uninstall removes exactly that line).
- `/boot/config/plugins/watchman/` — releases, config (`config/watchman.json`, `config/discord-webhook`).
- RAM only, rebuilt each boot: `/usr/local/emhttp/plugins/watchman/`, `/usr/local/bin/watchman`,
  `/var/run/watchman/`, log at `/var/log/watchman.log`.
- `/mnt/user/appdata/watchman/` — alert history, created only after the array is started.
- Never touched: the v0.3 install in `/boot/config/plugins/nas-watchman/` and `/mnt/user/appdata/nas-watchman/`.

## Hands-on trial checklist (new installation)
1. If you have a legacy v0.3 installation, decide whether to disable its User Script: it keeps running otherwise,
   so you may get duplicate alerts. `watchman status` warns when v0.3 is also running.
2. `bash install.sh`, then `watchman status` → running (array is started).
3. `watchman setup` → [1] detect the disks actually present on your machine, tick only
   containers that should always run; [7] add a private Discord webhook and send a test.
   Optional [9] enables standby-aware SMART monitoring; keep it off until you have reviewed
   your device and sleep settings. It never runs self-tests or deliberately writes disk data.
4. Stop the array in the Unraid UI → it stops cleanly (Watchman must not block unmounting);
   `watchman status` → waiting. Start the array → running again.
5. Reboot. If array autostart is disabled, Watchman should wait for the array; otherwise it
   should resume when `/mnt/user/appdata` is available. Check whether existing alerts are retried.
6. Optional: `watchman rollback` twice, then `watchman uninstall` → `/boot/config/go` matches
   `/boot/config/go.watchman-backup` again.
