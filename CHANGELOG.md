# Changelog

All notable changes to this project will be documented in this file.

## [1.6.1] - 2026-03-01
### Changed
- Lock handling hardened with owner checks, lock PID metadata, and stale-lock recovery.
- CLI handling tightened: unknown options and unexpected positional arguments now fail fast.
- `--dry-run` now has explicit precedence over config values.
- README operational docs refreshed with failure-aware Mermaid flowcharts and lifecycle outcomes.
- `docs/ISSUE_AUDIT.md` condensed into a release-facing summary.

### Fixed
- Config parsing now works on older Bash variants (including `/bin/bash` 3.2).
- Lock creation failures now return hard failure instead of false "already running" success.
- Secret scan now reports scanner errors correctly instead of treating them as clean runs.
- Temp files are created under `${TMPDIR:-/tmp}` to avoid unexpected cwd behavior.

## [1.6.0] - 2026-02-28
### Added
- CLI option `--config=FILE` or `-c FILE` to set config file path (alternative to `CONFIG_FILE` env).
- CLI option `--status`: print up-to-date or update available (local/remote buildid), then exit; no service stop/update/start.
- Example config file `cs2-auto-update.conf.example`; README Quick start and config file reference.
- Run duration in completion log (e.g. "Update process completed (12s)").
- Log level prefixes `[INFO]`, `[WARN]`, `[ERROR]` in log output for parsing.

### Changed
- Config loading extracted to `load_config_file()`; single list `CONFIG_AND_TRIM_VARS` for config whitelist and trim loop.
- Defaults consolidated into `apply_defaults()` (single source of truth, run after config load and after trim).
- Tests: removed redundant `tests/bin/df` (inline mock in `run.sh` only); added `run_validation_test()` helper for validation tests.
- Docs: `docs/ISSUE_AUDIT.md` condensed to a short decisions and audit summary.
- Makefile: comment that `ci` target order matches CI pipeline.

## [1.5.0] - 2026-02-19
### Added
- CLI options: `--help`, `--version`, `--dry-run` (lock + disk + buildid check only; no update).
- `LOG_LEVEL=quiet|normal|verbose` (quiet: only ERROR/WARNING).
- Optional config file: `CONFIG_FILE` or `cs2-auto-update.conf` next to script; same keys as env.
- Optional webhook notification on successful update: `NOTIFY_WEBHOOK_URL` (e.g. Discord/Slack).
- `scripts/shell-files.env` as single source of script list for `lint.sh` and `fmt.sh`.
- LOGFILE path validation (no `..`).

### Changed
- `.gitignore`: added `.cursor/`; slimmer (Bash-only repo).
- README: exit codes, config file, webhook, and repository structure (`shell-files.env`).

## [1.4.0] - 2026-01-31
### Added
- Remote buildid check via `steamcmd +app_info_print` to avoid unnecessary service restarts when up-to-date.
- Lightweight stub-based test harness (`tests/run.sh`) to validate control flow without Steam/systemd.
- New config knobs: `CS2_APP_ID`, `SLEEP_SECS` plus test helpers `ALLOW_NONROOT`/`NO_SLEEP`.

### Changed
- Running SteamCMD as `steam` no longer requires `sudo` specifically; the script uses `runuser`/`su`/`sudo` (best-effort).
- Preserve existing `PATH` (append `/usr/games`) instead of overwriting it.

## [1.3.0] - 2026-01-31
### Added
- Local/CI lint tooling via `scripts/lint.sh` and GitHub Actions.
- `shfmt` auto-format helper via `scripts/fmt.sh`.
- Optional buildid-based update detection via `steamapps/appmanifest_730.acf`.

### Changed
- Switched lockfile to an atomic lock directory (`LOCKDIR`) to avoid startup races.
- Hardened script with `set -euo pipefail` and explicit dependency checks.
- Logging now writes to stdout and appends to `LOGFILE` (better for cron/journald).

## [1.2.0] - 2025-04-18
### Added
- **Precise update detection:** Regex pattern extended to match both `up-to-date` variants and `download complete`.
- **Service health check:** Added `ensure_service_running()` to confirm service status when no update is applied.

### Changed
- Improved logging messages for better clarity in success and error cases.
- Enhanced `cleanup()` to remove lockfile only if it was created by this run.

### Fixed
- None.

## [1.1.0] - 2025-04-02
### Added
- **Modularization:** Broke script into functions (`init_lock()`, `check_space()`, `stop_service()`, etc.) for readability and maintenance.
- **Trap cleanup:** Added `trap cleanup EXIT` to ensure lockfile removal on unexpected exit.
- **Retry logic:** Configurable retry loops for service stop/start operations.

### Changed
- Moved configuration variables to top of script for easier customization.
- Switched disk-check command to `df --output=avail` for more reliable parsing.

### Fixed
- None.

## [1.0.0] - 2025-03-15
### Added
- Initial release of `update_cs2.sh`.
  - Lockfile mechanism to prevent overlapping runs.
  - Disk-space check (default 5 GB).
  - Stops CS2 service (`cs2.service`) before update.
  - Performs SteamCMD update with `+app_update 730 validate`.
  - Parses SteamCMD output for “already up-to-date.”
  - Restarts service only when update applied.
  - Detailed timestamped logging.
  - Designed for execution via root cron with logrotate support.

### Changed
- N/A

### Fixed
- N/A

## [0.1.0] - DEPRECATED
This version was an experimental prototype and is no longer supported.
