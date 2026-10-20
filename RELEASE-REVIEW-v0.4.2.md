# NAS Watchman v0.4.2 — release review
Status: ISOLATED TESTED PROTOTYPE; NOT DEPLOYED

## Changes
- Interactive configuration wizard, disk/container discovery preview, validation and backup/restore.
- Sidecar or local read-only metrics collection.
- Configurable Ollama model; simulated Ollama API tests.
- Existing alert/report engine with simulated Discord delivery security tests.
- .gitignore and sanitized watchman.json.example; actual Discord webhook is a separate private file.

## Evidence
- 42/42 unit and simulated integration tests passed October 20, 2026.
- Bash syntax checks passed.
- No real Discord or Ollama API requests in tests.
- Local development folder is not a Git repository.

## Risks and limits
- No live Unraid compatibility test (disk INI, Docker, GPU, syslog).
- No independent dead-man monitor: planned for v0.5.
- Discord may duplicate messages on ambiguous delivery outcomes.
- No complete credential exposure audit of a future GitHub repository.
- SMART Pre-fail labels are not evaluated; cached Unraid disk status is used.
- Config file rename is atomic on the same filesystem, but power-loss durability is not guaranteed.
- Passing simulated tests does not prove production safety.

## Publication gates
1. Review full source, tests, README, and change diff.
2. Check target repository history and staging for credentials before any push.
3. Explicit approval to publish. Publishing is NOT deployment.

## Deployment gates
1. Explicit approval for read-only, no-notification compatibility check on JohnsVault.
2. Capture checksums, ownership, permissions, running service and backup of scripts/config/state.
3. Stage in separate versioned paths, verify metrics, and limit trial notifications.
4. Explicit approval before enabling ongoing monitoring.

## Rollback
Stop only the new trial worker. Restore original scripts, config, and state from
verified backups, leaving volumes, networking, and protected deployments unchanged.
Verify the original worker and alerts before considering rollback complete.
