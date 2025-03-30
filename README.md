# CS2 Auto Update Script
This repository contains a robust Bash script designed to automatically update your Counter-Strike 2 Dedicated Server using SteamCMD. The script stops the CS2 service, runs the update, and restarts the service if an update is applied. It includes detailed logging, error handling with retries, and an update-check mechanism to avoid unnecessary restarts.

## Features

- **Service Management:**  
  - Stops the CS2 service (`cs2.service`) before performing the update.
  - Restarts the service after the update is complete (only if an update was applied).
  - Implements retry logic for stopping and starting the service.

- **Update Process:**  
  - Executes SteamCMD to update the server installation.
  - Checks SteamCMD output to determine whether an update was necessary.
  - Avoids a restart if the server is already up-to-date.

- **Robust Error Handling:**  
  - Uses a lockfile to prevent concurrent script executions.
  - Checks for sufficient free disk space before proceeding.
  - Aborts the process if any critical step fails.

- **Logging:**  
  - Logs every step with timestamps into a log file.
  - Can be integrated with logrotate to prevent unbounded log growth.

## Requirements

- **Operating System:** Ubuntu 22.04 (or a compatible Linux distribution)
- **User:** The script is intended to be run as the root user (e.g., via cron) to manage system services without sudo password prompts.
- **SteamCMD:** Must be installed and accessible (commonly located at `/usr/games/steamcmd`).
- **CS2 Installation:** The CS2 server should be installed in `/home/steam/cs2`
- **Systemd:** For managing the CS2 service (the service is named `cs2.service`)

## Installation

1. **Clone this Repository:**

   ```bash
   git clone https://github.com/yourusername/cs2-auto-update.git
   cd cs2-auto-update´´´
   ```
2. **Deploy the Script:**
   Copy the update_cs2.sh script to your desired location (for example, /home/steam/update_cs2.sh):
   ```bash
   cp update_cs2.sh /home/steam/update_cs2.sh
   ```
3. **Set Permissions:**
   Make the script executable:
   ```bash
   chmod +x /home/steam/update_cs2.sh
   ```
4. **Review and Configure:**
   Open /home/steam/update_cs2.sh in your favorite text editor and adjust the following variables as needed:
    - LOCKFILE: Path to the lock file (default: `/tmp/update_cs2.lock`)
    - LOGFILE: Path to the log file (default: `/home/steam/update_cs2.log`)
    - CS2_DIR: Directory where your CS2 server is installed (default: `/home/steam/cs2`)
    - REQUIRED_SPACE: Minimum free space required in KB (default: `5000000` for ~5GB)
    - MAX_ATTEMPTS: Maximum number of attempts to stop/start the service (default: `5`)

## Usage

### Manual Execution
** To manually update your CS2 server, run:**
  ```bash
  /home/steam/update_cs2.sh
  ```
The script will log its output to /home/steam/update_cs2.log.

### Scheduling with Cron
To schedule the script to run, e.g., daily at 07:00 AM, add the following entry to the root crontab:
  1. Open the root crontab for editing:
  ```bash
  sudo crontab -e
  ```
  2. Add this line:
  ```bash
  0 7 * * * /home/steam/update_cs2.sh >> /home/steam/update_cs2.log 2>&1
  ```

## Log Rotation
To prevent the log file from growing indefinitely, create a Logrotate configuration. For example, create `/etc/logrotate.d/cs2_update` with the following content:
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
        # Optional: Add any post-rotation commands here.
    endscript
}
```
This configuration rotates the log file daily, keeps 7 old logs, compresses them, and ensures that the log file is recreated with the proper permissions.

## Script Workflow
1. Lockfile Creation:
   The script creates a lockfile to prevent multiple instances from running simultaneously.
2. Disk Space Check:
   It verifies that there is enough free disk space in the CS2 installation directory.
3. Service Stop:
   The script attempts to stop the CS2 service (cs2.service) with retry logic.
4. SteamCMD Update:
   The update is executed via SteamCMD. The script checks the output for the phrase "already up-to-date" to determine if any updates were applied.
5. Service Start:
   If an update is applied (or if the service was stopped), the script restarts the CS2 service with retries if necessary.
6. Logging:
   All steps are logged with timestamps to a specified log file.
7. Lockfile Removal:
   Finally, the lockfile is removed so that future updates can run.

## Customization and Improvements
- Notifications:
  You can extend the script to send notifications (via email or messaging services) in case of failures or successful updates.
- External Configuration:
  Consider moving configuration variables into a separate file to simplify maintenance.
- Enhanced Debugging:
  More detailed logging or verbose mode can help troubleshoot issues.

## Troubleshooting
- Lockfile Issues:
  If the script complains that an update process is already running, check and remove `/tmp/update_cs2.lock` manually if needed.
- Permission Errors:
  Ensure that the script and log directories have the correct permissions.
- Service Not Restarting:
  Verify that the CS2 service is properly defined in systemd and that the paths and parameters in the script match your setup.
