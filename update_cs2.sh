#!/bin/bash
# update_cs2.sh - Updates the CS2 Dedicated Server and restarts it if an update is applied.
#
# Modularized and hardened:
#   - Precise update detection via regex
#   - Lockfile with controlled cleanup via trap
#   - Functions for each logical step
#   - SteamCMD run as 'steam' user under root cron
#   - Robust logging and error handling
#
# Usage:
#   Run as root (e.g., via cron) so no sudo prompts are needed.
#   Configure the variables below to match your environment.

set -e
set -o pipefail

#### Configuration ####
LOCKFILE="/tmp/update_cs2.lock"
LOGFILE="/home/steam/update_cs2.log"
CS2_DIR="/home/steam/cs2"
SERVICE_NAME="cs2.service"
REQUIRED_SPACE=5000000    # in KB (e.g., ~5GB)
MAX_ATTEMPTS=5

#### Internal state ####
CLEANUP_ENABLED=0

#### Helper Functions ####
log() {
    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$ts] $*" >> "$LOGFILE"
}

exit_with_error() {
    log "ERROR: $*"
    cleanup
    exit 1
}

cleanup() {
    # Remove the lockfile if it was created
    if [ "$CLEANUP_ENABLED" -eq 1 ] && [ -e "$LOCKFILE" ]; then
        rm -f "$LOCKFILE"
        log "Lockfile removed."
    fi
}
trap cleanup EXIT

#### Step 1: Create Lockfile ####
init_lock() {
    if [ -e "$LOCKFILE" ]; then
        log "An update process is already running. Exiting."
        exit 0
    fi
    touch "$LOCKFILE"
    CLEANUP_ENABLED=1
    log "Lockfile created."
}

#### Step 2: Check Disk Space ####
check_space() {
    local avail
    avail=$(df --output=avail "$CS2_DIR" | tail -1)
    if [ "$avail" -lt "$REQUIRED_SPACE" ]; then
        exit_with_error "Not enough free disk space ($avail KB available, $REQUIRED_SPACE KB required)."
    fi
    log "Disk space check passed ($avail KB available)."
}

#### Step 3: Stop Service ####
stop_service() {
    log "Stopping $SERVICE_NAME..."
    local attempt=1
    until systemctl stop "$SERVICE_NAME"; do
        if [ $attempt -ge $MAX_ATTEMPTS ]; then
            exit_with_error "Failed to stop $SERVICE_NAME after $MAX_ATTEMPTS attempts."
        fi
        log "Attempt $attempt: stop failed, retrying in 5s..."
        sleep 5
        attempt=$((attempt+1))
    done
    log "$SERVICE_NAME stopped."
    sleep 5
}

#### Step 4: Run SteamCMD Update ####
run_update() {
    log "Running SteamCMD update as 'steam' user..."
    UPDATE_OUTPUT=$(sudo -u steam /usr/games/steamcmd +login anonymous \
        +force_install_dir "$CS2_DIR" \
        +app_update 730 validate +quit 2>&1)
    log "SteamCMD output:"
    log "$UPDATE_OUTPUT"
}

#### Step 5: Determine if Update Was Applied ####
check_update_need() {
    # Match variants of "up-to-date" or "download complete"
    if echo "$UPDATE_OUTPUT" | grep -Eiq "(already up[ -]?to[ -]?date|download complete)"; then
        log "No new updates found."
        return 1
    fi
    log "Update applied."
    return 0
}

#### Step 6: Start Service ####
start_service() {
    log "Starting $SERVICE_NAME..."
    local attempt=1
    until systemctl start "$SERVICE_NAME"; do
        if [ $attempt -ge $MAX_ATTEMPTS ]; then
            exit_with_error "Failed to start $SERVICE_NAME after $MAX_ATTEMPTS attempts."
        fi
        log "Attempt $attempt: start failed, retrying in 5s..."
        sleep 5
        attempt=$((attempt+1))
    done
    log "$SERVICE_NAME started."
}

#### Step 7: Ensure Service Running ####
ensure_service_running() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log "$SERVICE_NAME is already running."
    else
        log "$SERVICE_NAME is not running; starting..."
        start_service
    fi
}

#### Main Execution Flow ####
log "=== Update process initiated ==="
init_lock
check_space
stop_service
run_update

if check_update_need; then
    start_service
else
    ensure_service_running
fi

log "=== Update process completed ==="
exit 0
