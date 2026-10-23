# NAS Watchman v0.4.3 (development preview)

Read-only Unraid NAS monitoring prototype with a setup wizard, optional local telemetry, cached disk-status checks, stateful alerts, optional Ollama summaries, and Discord notifications.

**Development preview only. Do not install over a running Watchman instance.** The existing production deployment is not part of this change.

## v0.4.3 cached parity status

This development branch reports cached Unraid parity/parity2 slot assignment and disk status. Interpret these cases separately:

| Cached observation | Interpretation |
| --- | --- |
| Parity slot unassigned | No disk configured in that parity slot. This is not automatically a disk failure; do not imply parity protection exists. |
| Parity assigned, status `DISK_OK` | Cached disk status reports OK. This does **not** prove parity integrity, successful reconstruction, or a completed parity check. |
| Parity assigned, failed status | Report a disk-status problem and raise an alert. |
| Parity assigned, unknown status | Raise an uncertainty warning; never treat unknown as healthy. |
| Cached status data unavailable | Report uncertainty; do not infer health from missing data. |

**Recovery disclaimer: A recovery notification means the previously reported warning has cleared. It does not independently verify parity integrity, successful reconstruction, or completed parity checks.**

This is status reporting, **not** parity verification. It does not perform parity checks, repair disks, reconstruct data, or validate live parity-enabled hardware behavior.

## Files

- `watchman.sh` — launcher and configuration wizard
- `watchman_engine.sh` — reporting and alert engine
- `watchman_local_metrics.py` — local read-only collector
- `watchman.json.example` — sanitized configuration example
- `test_*.py` — offline Python regression tests
- `test_parity_fixtures.sh` — parity fixture checks
- `test_parity_alert_lifecycle.sh` — isolated alert/recovery lifecycle tests
- `RELEASE-REVIEW-v0.4.2.md` — earlier risk assessment, release gates, and rollback notes

## Offline tests

From the project directory:

```sh
python3 -m unittest discover -p 'test_*.py' -q
bash -n watchman.sh watchman_engine.sh
bash test_parity_fixtures.sh
bash test_parity_alert_lifecycle.sh
```

Development-branch QA recorded 42 Python regression tests, 4 parity fixture scenarios, and 2 alert lifecycle scenarios passing (48 total). These tests use mocked or isolated interfaces. **They are not proof of real-hardware compatibility, live Discord delivery, or parity integrity.**

## Configuration and security

The launcher validates `watchman.json`, uses private permissions and backups, and keeps the Discord webhook outside JSON configuration. Never commit real webhooks, private configuration, or private logs. The engine defaults to local telemetry and Ollama endpoints; review settings before use. No automatic repairs or SMART testing.

## Known limitations and release gate

Disk health is based on cached Unraid status, not comprehensive SMART analysis. No independent process heartbeat. Live parity-enabled NAS behavior, real-host compatibility, and live Discord delivery remain unverified.

**Deployment is not authorized.** Review documentation and code, validate host compatibility safely, and obtain explicit deployment approval before any production change. Keep the running Watchman instance untouched.
