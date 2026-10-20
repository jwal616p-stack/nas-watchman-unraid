# NAS Watchman v0.4.2 (development preview)

A read-only monitoring prototype for an Unraid NAS, with an interactive setup
wizard, optional local telemetry collection, cached disk-status checks,
stateful alerts, optional Ollama summaries, and Discord notifications.

**Not a production release. Do not install over a running Watchman instance.**

## Files
- watchman.sh — launcher and configuration wizard
- watchman_engine.sh — reporting and alert engine
- watchman_local_metrics.py — local read-only collector
- watchman.json.example — sanitized configuration example
- test_*.py — offline regression and simulated integration tests
- RELEASE-REVIEW-v0.4.2.md — risk assessment, release gates and rollback

## Local tests
Run from the project directory:
```sh
python3 -m unittest discover -p 'test_*.py' -q
bash -n watchman.sh watchman_engine.sh
```
Tests use mocked interfaces; do not treat passing tests as live NAS validation.

## Configuration and security
The launcher validates watchman.json, uses private permissions and backups,
and separates the Discord webhook from the JSON configuration.
Never commit a real webhook URL, local config, or private logs.
The engine defaults to local telemetry and Ollama endpoints. Review settings
before use. No automatic repairs or SMART testing.

## Known limitations
No independent process heartbeat. Disk health uses cached Unraid status, not
full SMART analysis. Real host compatibility and live Discord delivery are
unverified. See RELEASE-REVIEW-v0.4.2.md.

## Deployment
Not authorized. Complete code review, host compatibility validation and
explicit deployment approval first. Keep existing production Watchman untouched.
