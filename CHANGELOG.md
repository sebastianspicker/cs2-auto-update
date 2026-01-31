# Changelog

All notable changes to this project will be documented in this file.

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
