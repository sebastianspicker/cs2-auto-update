# Changelog

All notable changes to this project will be documented in this file.

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
