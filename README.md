# NAS Watchman v0.4.5-dev — read-only Unraid monitoring

**Development preview — not a general production release.** NAS Watchman watches an Unraid server without making disk, Docker, or array changes. It can deliver deduplicated alerts and recovery notices to Discord. A separate, older [v0.4.2 preview](https://github.com/jwal616p-stack/nas-watchman-unraid/tree/main) remains on `main`; this branch is the v0.4.5 development candidate.

Tested on one physical Unraid 7.4.0 installation (upgraded from 7.3.2) and in isolated simulations. Compatibility with other arrays, storage devices, drivers, and upgrades is **not guaranteed**. Review the source and [INSTALL.md](INSTALL.md) before installing.

## Monitoring features

- RAM and every GPU reported by NVIDIA `nvidia-smi`, including decimal temperatures introduced by NVIDIA 620 on Unraid 7.4.0; separate GPU warnings and device-change notices.
- Selected Docker containers, with alerts if they are not running. Container selection is configurable; Watchman **does not start or stop containers**.
- Cached Unraid parity/disk/pool status, temperatures and filesystem usage. A parity-status recovery does **not** prove parity integrity or reconstructability.
- Select new syslog events, including unsuccessful and successful logins, OOM, NVIDIA Xid, disk write errors, UAS recovery/reset, and USB disconnect/reset events. Generic USB notices may include keyboards and other non-storage devices. No raw log lines, usernames, IPs or disk serials are included in Discord alerts.
- Optional **standby-aware SMART** monitoring for eligible assigned SATA/NVMe disks, controlled by setup option 9. `smartctl -n standby -a -j` is used; USB and unselected pool/data drives are skipped. SMART monitoring may still have hardware-dependent behavior (especially with SAS). No SMART self-tests, repair or filesystem writes are performed. Missing readings are not treated as healthy.
- SMART status/counter warnings and class-based temperature thresholds (HDD 50/60°C warning/critical; SSD 60/70°C; NVMe 70/80°C). Valid explicitly configured per-drive or global limits override class defaults. Fresh Unraid temperatures take precedence over cached SMART temperature data.
- Persistent alert history, deduplication, change notices, recovery notifications, and optional local Ollama summaries. AI summaries are commentary, not an independently verified health assessment.

## Install or upgrade (experienced Unraid users)

From this **development branch** on the Unraid host, after reviewing the installer:

```bash
bash install.sh
watchman setup
watchman status
watchman report
```

The install preserves existing Watchman configuration and alert history, stages release files on the flash drive, and supports `watchman rollback`. It adds an Unraid boot hook and supervises the monitoring engine. The supervisor waits until the array and `/mnt/user/appdata` are ready; monitoring does not require array autostart. See [INSTALL.md](INSTALL.md) for upgrade, rollback, cleanup, and safe first-run checks.

**Do not enter or commit real Discord webhook URLs, credentials, server logs, or machine-specific configuration into Git.** The bundled [watchman.json.example](watchman.json.example) intentionally contains no private data. Monitoring is read-only with respect to your disks and Docker, but the installer **does** write program/config files and the monitor maintains alert history.

## Testing and current status

- **97 Python tests pass** with both jq 1.7.1 and jq 1.8.1, plus **nine offline shell suites** with each version.
- Regression tests include simulated Unraid roots, fake drives, SMART standby behavior, parity, syslog, GPU model/temperature changes, failed upgrades, rollback to pre-SMART code, and corrupted cache handling.
- Live checked on one Unraid 7.4.0 host: both GPUs, SMART sampling, no detected wakeups of sleeping pool drives, Discord delivery, array-stop/start supervision, and configuration changes. These tests do not establish reliability across hardware or future versions.
- NVIDIA 620 `nvidia-smi` fractional temperatures are accepted; unknown `[N/A]` values remain unavailable.
- **Known behavior:** monitoring a container that is intentionally stopped generates an alert; choose only services that should be running. A legacy alert without a reliable physical-drive identity can be delivered one additional time after upgrade.

Detailed engineering notes and limitations: [README-dev.md](README-dev.md). Older v0.4.2 release review: [RELEASE-REVIEW-v0.4.2.md](RELEASE-REVIEW-v0.4.2.md) (historical, **not** the approval document for this branch).
