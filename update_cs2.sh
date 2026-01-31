#!/bin/bash
# update_cs2.sh - Updates the CS2 Dedicated Server and restarts it if an update is applied.
#
# Modularized and hardened:
#   - Update detection via SteamCMD + optional buildid compare
#   - Atomic lock directory with controlled cleanup via trap
#   - Functions for each logical step
#   - SteamCMD run as 'steam' user under root cron
#   - Robust logging and error handling
#
# Usage:
#   Run as root (e.g., via cron) so no sudo prompts are needed.
#   Configure the variables below to match your environment.

set -euo pipefail

# Cron can provide a minimal PATH; keep common locations available.
PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}:/usr/games"
export PATH

#### Configuration ####
LOCKDIR="${LOCKDIR:-/tmp/update_cs2.lock}"
LOGFILE="${LOGFILE:-/home/steam/update_cs2.log}"
CS2_DIR="${CS2_DIR:-/home/steam/cs2}"
SERVICE_NAME="${SERVICE_NAME:-cs2.service}"
STEAMCMD="${STEAMCMD:-/usr/games/steamcmd}"
CS2_APP_ID="${CS2_APP_ID:-730}"
REQUIRED_SPACE="${REQUIRED_SPACE:-5000000}" # in KB (e.g., ~5GB)
MAX_ATTEMPTS="${MAX_ATTEMPTS:-5}"
SLEEP_SECS="${SLEEP_SECS:-5}"

# Testing helper: set to 1 to allow running as non-root (runs SteamCMD as the current user).
ALLOW_NONROOT="${ALLOW_NONROOT:-0}"
NO_SLEEP="${NO_SLEEP:-0}"

#### Internal state ####
CLEANUP_ENABLED=0
UPDATE_OUTPUT=""

#### Helper Functions ####
log() {
    local ts msg
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    msg="[$ts] $*"

    # Always emit to stdout for journald/cron capture; best-effort append to logfile.
    printf '%s\n' "$msg"
    printf '%s\n' "$msg" >> "$LOGFILE" 2> /dev/null || true
}

log_multiline() {
    local prefix line
    prefix="$1"
    shift
    while IFS= read -r line; do
        log "${prefix}${line}"
    done <<< "$*"
}

require_root() {
    if [ "$ALLOW_NONROOT" = "1" ]; then
        return 0
    fi

    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        log "ERROR: This script must run as root (e.g., via root cron)."
        exit 1
    fi
}

require_cmd() {
    local cmd
    cmd="$1"
    command -v "$cmd" > /dev/null 2>&1 || exit_with_error "Missing required command: $cmd"
}

ensure_logfile_writable() {
    local logdir
    logdir=$(dirname "$LOGFILE")
    mkdir -p "$logdir" || exit_with_error "Failed to create log directory: $logdir"
    touch "$LOGFILE" 2> /dev/null || exit_with_error "Log file is not writable: $LOGFILE"
}

sleep_s() {
    local secs
    secs="$1"

    if [ "$NO_SLEEP" = "1" ]; then
        return 0
    fi

    sleep "$secs"
}

exit_with_error() {
    log "ERROR: $*"
    cleanup
    exit 1
}

cleanup() {
    # Remove the lock dir if it was created by this run.
    if [ "$CLEANUP_ENABLED" -eq 1 ] && [ -d "$LOCKDIR" ]; then
        rmdir "$LOCKDIR" 2> /dev/null || rm -rf "$LOCKDIR"
        log "Lock removed."
    fi
}
trap cleanup EXIT

#### Step 1: Create Lock ####
init_lock() {
    # mkdir is atomic; avoids races when two instances start simultaneously.
    if mkdir "$LOCKDIR" 2> /dev/null; then
        CLEANUP_ENABLED=1
        log "Lock acquired."
        return 0
    fi

    log "An update process is already running (lock: $LOCKDIR). Exiting."
    exit 0
}

#### Step 2: Check Disk Space ####
check_space() {
    local avail
    avail=$(df --output=avail "$CS2_DIR" 2> /dev/null | awk 'NR==2 {print $1}')
    if [ -z "$avail" ]; then
        exit_with_error "Failed to determine free disk space for: $CS2_DIR"
    fi
    if [ "$avail" -lt "$REQUIRED_SPACE" ]; then
        exit_with_error "Not enough free disk space ($avail KB available, $REQUIRED_SPACE KB required)."
    fi
    log "Disk space check passed ($avail KB available)."
}

run_as_steam() {
    if [ "$ALLOW_NONROOT" = "1" ]; then
        "$@"
        return $?
    fi

    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        if command -v runuser > /dev/null 2>&1; then
            runuser -u steam -- "$@"
            return $?
        fi
        if command -v su > /dev/null 2>&1; then
            # shellcheck disable=SC2024
            su -s /bin/bash -c "$(printf '%q ' "$@")" steam
            return $?
        fi
        if command -v sudo > /dev/null 2>&1; then
            sudo -u steam "$@"
            return $?
        fi
        exit_with_error "Need one of: runuser, su, sudo (to run SteamCMD as 'steam' user)."
    fi

    require_cmd sudo
    sudo -u steam "$@"
}

retry_systemctl() {
    local action
    action="$1"

    local attempt
    for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
        if systemctl "$action" "$SERVICE_NAME"; then
            return 0
        fi
        if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
            log "Attempt ${attempt}/${MAX_ATTEMPTS}: systemctl $action failed, retrying in ${SLEEP_SECS}s..."
            sleep_s "$SLEEP_SECS"
        fi
    done

    return 1
}

#### Step 3: Stop Service ####
stop_service() {
    log "Stopping $SERVICE_NAME..."
    retry_systemctl stop || exit_with_error "Failed to stop $SERVICE_NAME after $MAX_ATTEMPTS attempts."
    log "$SERVICE_NAME stopped."
    sleep_s "$SLEEP_SECS"
}

#### Step 4: Run SteamCMD Update ####
run_update() {
    log "Running SteamCMD update as 'steam' user..."
    if ! UPDATE_OUTPUT=$(run_as_steam "$STEAMCMD" +login anonymous \
        +force_install_dir "$CS2_DIR" \
        +app_update "$CS2_APP_ID" validate +quit 2>&1); then
        log "SteamCMD output:"
        log_multiline "steamcmd: " "$UPDATE_OUTPUT"
        log "Attempting to start $SERVICE_NAME after failed update..."
        start_service || true
        exit_with_error "SteamCMD update failed."
    fi

    log "SteamCMD output:"
    log_multiline "steamcmd: " "$UPDATE_OUTPUT"
}

read_buildid() {
    local manifest
    manifest="${CS2_DIR%/}/steamapps/appmanifest_${CS2_APP_ID}.acf"

    if [ ! -f "$manifest" ]; then
        printf ''
        return 0
    fi

    # ACF is simple key/value; this is a best-effort parse.
    awk -F'"' '$2=="buildid"{print $4; exit}' "$manifest" 2> /dev/null || true
}

get_remote_buildid() {
    local output buildid

    if ! output=$(run_as_steam "$STEAMCMD" +login anonymous +app_info_update 1 +app_info_print "$CS2_APP_ID" +quit 2>&1); then
        log "SteamCMD app_info_print failed; output:"
        log_multiline "steamcmd: " "$output"
        printf ''
        return 0
    fi

    # Best-effort: find the buildid of the public branch (inside "branches" -> "public").
    buildid=$(
        awk -F'"' '
            /"branches"/ {in_branches=1}
            in_branches && /"public"/ {in_public=1}
            in_public && $2=="buildid" {print $4; exit}
        ' <<< "$output" 2> /dev/null
    )

    printf '%s' "$buildid"
}

#### Step 5: Start Service ####
start_service() {
    log "Starting $SERVICE_NAME..."
    retry_systemctl start || exit_with_error "Failed to start $SERVICE_NAME after $MAX_ATTEMPTS attempts."
    log "$SERVICE_NAME started."
}

#### Step 6: Ensure Service Running ####
ensure_service_running() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log "$SERVICE_NAME is already running."
    else
        log "$SERVICE_NAME is not running; starting..."
        start_service
    fi
}

#### Main Execution Flow ####
require_root
ensure_logfile_writable
require_cmd awk
require_cmd df
require_cmd grep
require_cmd systemctl

if [ ! -x "$STEAMCMD" ]; then
    exit_with_error "SteamCMD not found or not executable: $STEAMCMD"
fi

if [ ! -d "$CS2_DIR" ]; then
    exit_with_error "CS2_DIR does not exist: $CS2_DIR"
fi

log "=== Update process initiated ==="
init_lock
check_space

BUILDID_BEFORE=$(read_buildid)
log "Detected buildid before update: ${BUILDID_BEFORE:-unknown}"

REMOTE_BUILDID=$(get_remote_buildid)
log "Detected remote buildid: ${REMOTE_BUILDID:-unknown}"

if [ -n "$BUILDID_BEFORE" ] && [ -n "$REMOTE_BUILDID" ] && [ "$BUILDID_BEFORE" = "$REMOTE_BUILDID" ]; then
    log "No update required (local buildid matches remote)."
    ensure_service_running
    log "=== Update process completed ==="
    exit 0
fi

if [ -n "$BUILDID_BEFORE" ] && [ -n "$REMOTE_BUILDID" ] && [ "$BUILDID_BEFORE" != "$REMOTE_BUILDID" ]; then
    log "Update required (local buildid differs from remote)."
else
    log "Unable to determine update requirement reliably; falling back to safe update run."
fi

stop_service
run_update

BUILDID_AFTER=$(read_buildid)
log "Detected buildid after update: ${BUILDID_AFTER:-unknown}"

start_service

log "=== Update process completed ==="
exit 0
