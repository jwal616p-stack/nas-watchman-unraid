Historical notes from v0.4.2–v0.4.5 development. No private Discord credentials or live server configuration are committed. This branch is a **development preview**, not a universal production release.

## v0.4.5 development: opt-in SMART and high-temperature monitoring

- Development preview: branch `dev/v0.4.5-smart-monitoring`. Later installed and validated on one Unraid 7.4.0 NAS; other hardware remains unverified.
- Setup menu option 9 enables/disables SMART. Existing configurations default to disabled.
- Collector limits itself to Unraid-assigned SATA/SAS/NVMe parity and selected data/pool disks. USB devices, unselected data/pool disks, and boot flash are skipped. Legacy direct diagnostic calls without a selection argument still enumerate eligible drives.
- smartctl runs with -n standby -a -j and a 12-second timeout. It never starts SMART self-tests, writes to disks, repairs filesystems, or deliberately spins up sleeping drives.
- Alert modes cache SMART snapshots for 3600 seconds only when Unraid supplies nonempty stable drive IDs. Changing the drive identity or device assignment invalidates the cache; manual reports scan afresh. Unavailable or sleeping disks are not assumed healthy and do not clear existing alerts.
- Default temperature warning/critical thresholds: HDD 50/60 C; SATA SSD 60/70 C; NVMe 70/80 C.
- Override thresholds using WATCHMAN_SMART_HDD_WARN/CRIT, WATCHMAN_SMART_SSD_WARN/CRIT, and WATCHMAN_SMART_NVME_WARN/CRIT. The poll interval is WATCHMAN_SMART_INTERVAL (300..86400 seconds).
- Health alerts: explicit SMART overall failure, ATA pending and uncorrectable sectors, NVMe critical-warning flags and media errors. Valid error counters still alert when overall health/temperature are unknown. A first valid reading with nonzero reallocated sectors emits one warning; increases, or anomalous decreases on the SAME drive, emit separate notices. SATA CRC increases are compared against the last successfully delivered reading; initial CRC counts form a baseline. No automatic recovery is claimed for monotonic counters. Discord failures preserve the trend baseline for retry.
- Temperature is reconciled once per cycle under the same `disk_<slot>_temp` event. The current Unraid `disks.ini` temperature takes precedence over a cached SMART temperature, and a SMART-only temperature is used only if Unraid lacks a numeric temperature. Class-specific warning/critical limits stay consistent during SMART dropouts, using the prior identity-matched SMART class as needed; sleeping/unknown readings never imply recovery.
- Run test_smart_monitoring.sh with mocked lsblk/smartctl to test standby, high-temperature warning/critical and recovery, failed drive health, cache, and no USB probing without touching real storage or Discord.
- The `watchman rollback` command restores both release pointers, the prior RAM runtime and the previous running engine after an activation failure. Runtime swaps stage a full replacement before moving the old RAM copy aside.
- Regression coverage: `test_smart_regressions.sh`, `test_smart_monitoring.sh`, and `python3 -m unittest -q test_watchmanctl`, all on fake drives/roots. These particular tests never use real disks or Discord; separate limited live checks were performed later.

## v0.4.5 additional release-hardening checks

- Cross-version rollback accepts a real pre-SMART v0.4.4 (or earlier 0.4.x) release without `watchman_smart.sh`; it still fails closed for missing collector files in v0.4.5+ releases. Rollback and undo have isolated lifecycle regressions.
- SMART event transitions compare physical drive IDs, not only Unraid slot names. A replacement drive is not presented as a recovery of the old drive. Active events for displaced drives are preserved in local `retired-smart-incidents.json` and are not sent to Discord. SMART alerts without a stable drive ID fail closed rather than issuing a false recovery.
- A specific per-disk temperature limit takes priority over the class SMART warning. An explicitly configured global Unraid disk temperature limit (including explicitly set 55 C) takes priority next; otherwise the SMART HDD/SSD/NVMe warning defaults apply. A higher custom warning raises critical temperature accordingly, avoiding contradictory notices.
- Regression cases are in `test_smart_regressions.sh` and `test_watchmanctl.py`, with mocked disks and a fake Unraid root. Final release still requires live read-only compatibility checks and independent review.

## Post-Claude review fixes (local development only)

- R1: Invalid SMART cache timestamps or cached JSON bypass that cache, save one `*.invalid` local diagnostic copy when possible, and attempt a fresh standby-safe sample. If SMART collection fails, non-SMART status, disk and syslog alerts still run. No SMART failure may silently infer recovery.
- R2/R10: Reconcile one live-first disk temperature alert per physical drive. Cached SMART temperatures never hide newer Unraid temperature readings; source changes and collector failures retain prior class/threshold decisions and do not fabricate all-clears.
- R7: For a pre-SMART release, validate candidate configuration using that release's actual `--check-config` command before touching live runtime. Only `smart_enabled` may be stripped when necessary. The newer compatible controller is pinned on flash for reboot and undo; actual engine startup is verified, not merely the supervisor lock. After legacy configuration edits, rollback undo and reinstall preserve those edits and merge back only the saved `smart_enabled` preference. The target validates the merged configuration before activation; on failure, original config, pointers, archive, and running engine are restored. A partial or invalid archive blocks migration without discarding saved settings.
- R6/R8 and P3s: A global 55 C setting explicitly saved by the wizard is honored. Newly observed nonzero reallocated counts get one warning; anomalous decreases trigger a distinct notice; non-SMART disk event keys carry drive IDs when available. SMART probes respect explicitly selected data/pool disks while always including assigned parity.
- The offline test harness uses fake Unraid roots and mocked SMART output. Both jq versions (1.7.1/1.8.1) passed the suite. A limited live deployment and read-only SMART verification subsequently succeeded on Unraid 7.4.0; independent review of this final build and broader compatibility testing remain outstanding.

## Second-review cleanup (Nov 15, 2026)

- P2: Rolling forward after editing disk lists or alert thresholds on v0.4.4 now preserves those edits and adds **only** `smart_enabled` from the archived newer config. The same merge is performed during a direct reinstall. Reinstall cannot silently disable SMART or leave its archived setting stranded on flash. Target config validation, atomic config activation, and a running-engine check precede archive cleanup; failed activation restores the original config/archive/pointers and stops the broken supervisor before restarting the old release. Recovery sleeps are interruptible in 5-second chunks.
- P3 example: `watchman.json.example` intentionally **omits** `disk_temp_default`, so an untouched copy retains class-specific SMART HDD/SSD/NVMe thresholds. Including the key explicitly (including a value of 55) overrides those class defaults.
- P3 unknown class: USB transports are never SMART-probed. Until a trustworthy matching drive class is available, a numeric Unraid temperature uses the general 55 C fallback (or configured global/per-disk warning), without pretending to know a class-specific CRITICAL limit. An existing warning is not cleared/de-escalated just because class data disappeared. Real class-specific recovery resumes when known again.
- Conservative known tradeoff: on upgrading legacy alert history that has **no physical drive ID**, an active disk warning can be sent again once. We deliberately do not guess which drive produced an old alert; a potentially duplicate warning is safer than silently marking a replaced failing drive recovered.
- Regression tests include actual v0.4.4 source, edited configuration preserved on undo and reinstall, repeat rollback/undo, malformed and partial archives, forced supervisor-start failure, a crashing new worker, and missing SMART classification. Tests performed on a development laptop; the subsequent live deployment was separately verified on one Unraid 7.4.0 host.

## Unraid 7.4.0 NVIDIA 620 decimal-temperature compatibility hotfix

- Accept finite bounded fractional temperatures (`40.41 C`, `46.31 C`) in the local NVIDIA telemetry collector without weakening integer validation for GPU index, utilization, or VRAM counts. Unknown `[N/A]` values remain unavailable. Each GPU warning continues to be compared numerically to its threshold.
- The running NAS has several old disposable JohnsVault testing containers; remove those names from its monitoring configuration only. Do not remove, stop or mutate those Docker containers or change preserved alert history.

## First live Unraid 7.4.0 compatibility check (Nov 15, 2026)

- A 7.3.2 to 7.4.0 upgrade exposed NVIDIA 620.70.06 fractional GPU temperatures (`40.41`, `46.31`) that the integer-only collector incorrectly treated as unavailable. Fixed in commit `af0add0` without accepting fractional counters or indices; live read-only sampling and mock regressions now pass.
- The hotfix was installed through the standard Watchman upgrade mechanism, preserved Discord configuration/alert history, and left the previous release available for rollback. Two GPUs, SMART monitoring, mounted array/pools, and configured notifications were observed working after the hotfix.
- **QA at the latest source commit:** 97/97 Python tests and 9/9 shell suites each on jq 1.7.1 and 1.8.1. On one real host, standby drives were observed remaining in standby during SMART collection; this is not a universal guarantee for all controllers.
- Seven temporary development containers were excluded from the **local NAS configuration only**, not deleted, and no private host configuration is part of this repository.
- No general public release is claimed; broader review and testing are still advisable.
