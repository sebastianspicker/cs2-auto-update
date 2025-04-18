# CS2 Auto‑Update Script

A robust, modular Bash script that keeps your Counter‑Strike 2 Dedicated Server up‑to‑date. It stops the CS2 service, runs a SteamCMD update, and restarts the service **only if** new updates were applied (or to ensure it’s running). Built‑in logging, error handling, retries and disk‑space checks make it production‑ready.

## Table of Contents

- Features  
- Requirements  
- Installation  
- Configuration  
- Usage  
  - Manual Execution  
  - Scheduling with Cron  
- Log Rotation  
- Workflow  
- Customization  
- Troubleshooting  
- License  

## Features

- **Modular Design**  
  Each logical step lives in its own function (`init_lock()`, `check_space()`, `stop_service()`, etc.) for clarity and maintainability.

- **Precise Update Detection**  
  Uses a regular expression to match variants of “already up‑to‑date” **or** “download complete.” Avoids reliance on a single literal string.

- **Service Management with Retries**  
  Stops and starts the systemd service (`cs2.service`) with configurable retry attempts.

- **Lockfile Mechanism**  
  Prevents concurrent runs; cleans up reliably even on unexpected exits (`trap cleanup EXIT`).

- **Disk‑Space Check**  
  Verifies at least 5 GB (configurable) is free before fetching updates.

- **SteamCMD as Non‑Root**  
  Invokes SteamCMD under the `steam` user to keep ownerships and permissions correct.

- **Comprehensive Logging**  
  Logs every action with timestamps to `/home/steam/update_cs2.log`. Designed to work with logrotate.

## Requirements

- **OS:** Ubuntu 22.04 (or compatible)  
- **User Setup:**  
  - CS2 files installed under `/home/steam/cs2`  
  - Systemd service named `cs2.service`  
- **Tools:**  
  - `steamcmd` installed (typically `/usr/games/steamcmd`)  
  - Bash shell (script uses `set -e` and `pipefail`)  

## Installation

1. Clone Repository  
   ```bash
   git clone https://github.com/yourusername/cs2-auto-update.git
   cd cs2-auto-update
   ```

2. Deploy Script  
   ```bash
   cp update_cs2.sh /home/steam/update_cs2.sh
   ```

3. Make Executable  
   ```bash
   chmod +x /home/steam/update_cs2.sh
   ```

## Configuration

At the top of `/home/steam/update_cs2.sh`, adjust:

| Variable         | Description                                        | Default                         |
|------------------|----------------------------------------------------|---------------------------------|
| `LOCKFILE`       | Path to the lockfile                               | `/tmp/update_cs2.lock`          |
| `LOGFILE`        | Path to the log file                               | `/home/steam/update_cs2.log`    |
| `CS2_DIR`        | CS2 installation directory                         | `/home/steam/cs2`               |
| `SERVICE_NAME`   | Systemd service name                               | `cs2.service`                   |
| `REQUIRED_SPACE` | Minimum free space in KB before updating           | `5000000` (≈5 GB)               |
| `MAX_ATTEMPTS`   | Retry attempts for stopping/starting the service   | `5`                             |

## Usage

### Manual Execution

```bash
sudo /home/steam/update_cs2.sh
```

The script will log its progress to `/home/steam/update_cs2.log`.

### Scheduling with Cron

Run as root so no password prompts are needed:

1. Edit root’s crontab:  
   ```bash
   sudo crontab -e
   ```
2. Add the entry to run daily at 07:00:  
   ```cron
   0 7 * * * /home/steam/update_cs2.sh >> /home/steam/update_cs2.log 2>&1
   ```

## Log Rotation

Create `/etc/logrotate.d/cs2_update`:

```conf
/home/steam/update_cs2.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0644 steam steam
    sharedscripts
    postrotate
        # No service reload needed
    endscript
}
```

- **daily:** rotate every day  
- **rotate 7:** keep one week of logs  
- **compress/delaycompress:** gzip old logs  

## Workflow

1. **Lockfile**  
   Prevents overlapping runs.  
2. **Disk‑Space Check**  
   Aborts if insufficient space.  
3. **Stop Service**  
   Retries up to `MAX_ATTEMPTS` on failure.  
4. **SteamCMD Update**  
   Runs under `steam` user; captures output.  
5. **Update Detection**  
   Uses regex to detect if new files were downloaded.  
6. **Start Service**  
   If updated (or simply to ensure it’s running), restarts with retries.  
7. **Cleanup**  
   Removes lockfile on normal or abnormal exit.  

## Customization

- **Notifications:**  
  Integrate email/Slack/Telegram alerts on success or failure.  
- **External Config:**  
  Move variables into `/etc/cs2-update.conf` for easier maintenance.  
- **Verbose Mode:**  
  Add a `--verbose` flag to increase log detail.  

## Troubleshooting

- **“Already running” message:**  
  Remove stale lockfile:  
  ```bash
  rm -f /tmp/update_cs2.lock
  ```
- **Permission Denied:**  
  Ensure script, log directory, and CS2 files are owned by `steam` and/or accessible by root.  
- **Service Fails to Start/Stop:**  
  Verify `cs2.service` exists and works manually:  
  ```bash
  systemctl status cs2.service
  ```
