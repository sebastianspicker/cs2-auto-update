#!/bin/bash
# update_cs2.sh - Updates the CS2 Dedicated Server and restarts it if an update is applied.
# 
# This script performs the following steps:
#   1. Creates a lockfile to prevent multiple instances from running simultaneously.
#   2. Checks if there is sufficient free disk space.
#   3. Stops the CS2 service, retrying up to a maximum number of attempts.
#   4. Executes an update using SteamCMD and captures its output.
#   5. Checks if the server is already up-to-date and, if so, starts the service without a restart.
#   6. If an update was applied, restarts the CS2 service, again retrying if needed.
#   7. Removes the lockfile and logs all actions with timestamps.
#
# The log file is managed via Logrotate (see example configuration below) to prevent it from growing indefinitely.

set -e
set -o pipefail

# Configuration (customizable)
LOCKFILE="/tmp/update_cs2.lock"
LOGFILE="/home/steam/update_cs2.log"
CS2_DIR="/home/steam/cs2"
REQUIRED_SPACE=5000000  # in KB (e.g., 5GB required)
MAX_ATTEMPTS=5

# Get the current timestamp for logging
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

# Create a lock file to prevent concurrent executions
if [ -e "$LOCKFILE" ]; then
    echo "[$TIMESTAMP] An update process is already running. Exiting." >> "$LOGFILE"
    exit 1
fi
touch "$LOCKFILE"

echo "[$TIMESTAMP] Starting update process..." >> "$LOGFILE"

# Check if there is sufficient free disk space in the CS2 directory
AVAILABLE_SPACE=$(df "$CS2_DIR" | tail -1 | awk '{print $4}')
if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
    echo "[$TIMESTAMP] Error: Not enough free disk space ($AVAILABLE_SPACE KB available, $REQUIRED_SPACE KB required)." >> "$LOGFILE"
    rm -f "$LOCKFILE"
    exit 1
fi

# Attempt to stop the CS2 server service; try up to MAX_ATTEMPTS times if necessary
echo "[$TIMESTAMP] Stopping cs2.service..." >> "$LOGFILE"
attempt=1
while ! sudo systemctl stop cs2.service && [ $attempt -le $MAX_ATTEMPTS ]; do
    echo "[$TIMESTAMP] Attempt $attempt: Failed to stop the service." >> "$LOGFILE"
    sleep 5
    attempt=$((attempt+1))
done

if [ $attempt -gt $MAX_ATTEMPTS ]; then
    echo "[$TIMESTAMP] Error: Could not stop the service after $MAX_ATTEMPTS attempts." >> "$LOGFILE"
    rm -f "$LOCKFILE"
    exit 1
fi
echo "[$TIMESTAMP] Service stopped successfully." >> "$LOGFILE"

# Wait a short period to ensure the service has completely stopped
sleep 5

# Execute the update using SteamCMD and capture the output
echo "[$TIMESTAMP] Running update via SteamCMD..." >> "$LOGFILE"
UPDATE_OUTPUT=$(/usr/games/steamcmd +login anonymous +force_install_dir "$CS2_DIR" +app_update 730 validate +quit 2>&1)
echo "$UPDATE_OUTPUT" >> "$LOGFILE"

# Check if the update output indicates that the server is already up-to-date
if echo "$UPDATE_OUTPUT" | grep -qi "already up-to-date"; then
    echo "[$TIMESTAMP] No new updates found. Starting the service without a restart." >> "$LOGFILE"
    sudo systemctl start cs2.service
    rm -f "$LOCKFILE"
    exit 0
fi

echo "[$TIMESTAMP] Update applied. Restarting cs2.service..." >> "$LOGFILE"
attempt=1
while ! sudo systemctl start cs2.service && [ $attempt -le $MAX_ATTEMPTS ]; do
    echo "[$TIMESTAMP] Attempt $attempt: Failed to start the service." >> "$LOGFILE"
    sleep 5
    attempt=$((attempt+1))
done

if [ $attempt -gt $MAX_ATTEMPTS ]; then
    echo "[$TIMESTAMP] Error: Could not start the service after $MAX_ATTEMPTS attempts." >> "$LOGFILE"
    rm -f "$LOCKFILE"
    exit 1
fi

echo "[$TIMESTAMP] Service started successfully." >> "$LOGFILE"
echo "[$TIMESTAMP] Update process completed." >> "$LOGFILE"

# Remove the lock file
rm -f "$LOCKFILE"
exit 0
