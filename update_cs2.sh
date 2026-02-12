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
# Trim leading/trailing whitespace so " 5 " etc. is valid
LOCKDIR="${LOCKDIR#[[:space:]]*}"
LOCKDIR="${LOCKDIR%[[:space:]]*}"
REQUIRED_SPACE="${REQUIRED_SPACE#[[:space:]]*}"
REQUIRED_SPACE="${REQUIRED_SPACE%[[:space:]]*}"
MAX_ATTEMPTS="${MAX_ATTEMPTS#[[:space:]]*}"
MAX_ATTEMPTS="${MAX_ATTEMPTS%[[:space:]]*}"
SLEEP_SECS="${SLEEP_SECS#[[:space:]]*}"
SLEEP_SECS="${SLEEP_SECS%[[:space:]]*}"
# Normalize empty to default (e.g. LOCKDIR="" or trimmed to "" from env)
[ -z "$LOCKDIR" ] && LOCKDIR="/tmp/update_cs2.lock"
[ -z "$REQUIRED_SPACE" ] && REQUIRED_SPACE="5000000"
[ -z "$MAX_ATTEMPTS" ] && MAX_ATTEMPTS="5"
[ -z "$SLEEP_SECS" ] && SLEEP_SECS="5"

# Testing helper: set to 1 to allow running as non-root (runs SteamCMD as the current user).
ALLOW_NONROOT="${ALLOW_NONROOT:-0}"
NO_SLEEP="${NO_SLEEP:-0}"

#### Internal state ####
CLEANUP_ENABLED=0
TMP_UPDATE_OUTPUT=""
TMP_GET_REMOTE_BUILDID=""

#### Helper Functions ####
log() {
    local ts msg
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    msg="[$ts] $*"

    # Always emit to stdout for journald/cron capture; best-effort append to logfile.
    printf '%s\n' "$msg"
    printf '%s\n' "$msg" >> "$LOGFILE" 2> /dev/null || true
}

# Read from stdin to avoid ARG_MAX when logging large output (e.g. SteamCMD).
# Call only with stdin connected (e.g. log_multiline "prefix" < file or ... | log_multiline "prefix").
log_multiline() {
    local prefix line
    prefix="${1:-}"
    while IFS= read -r line; do
        log "${prefix}${line}"
    done
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

# Ensure the 'steam' user exists when we need to run commands as that user.
require_steam_user() {
    if [ "$ALLOW_NONROOT" = "1" ]; then
        return 0
    fi
    if ! id -u steam > /dev/null 2>&1; then
        exit_with_error "User 'steam' does not exist. Create it or set ALLOW_NONROOT=1 for testing."
    fi
}

require_cmd() {
    local cmd
    cmd="$1"
    command -v "$cmd" > /dev/null 2>&1 || exit_with_error "Missing required command: $cmd"
}

# Validate numeric config and LOCKDIR; call after require_root so we can exit_with_error.
validate_config() {
    if [[ "$LOCKDIR" == *".."* ]]; then
        exit_with_error "LOCKDIR must not contain '..': $LOCKDIR"
    fi
    if [ -L "$LOCKDIR" ]; then
        exit_with_error "LOCKDIR must not be a symlink. Use a real directory: $LOCKDIR"
    fi
    if [ -e "$LOCKDIR" ] && [ ! -d "$LOCKDIR" ]; then
        exit_with_error "Lock path exists but is not a directory (stale file?). Remove it: $LOCKDIR"
    fi
    if ! [[ "$REQUIRED_SPACE" =~ ^[0-9]+$ ]] || [ "$REQUIRED_SPACE" -lt 0 ]; then
        exit_with_error "REQUIRED_SPACE must be a non-negative integer (KB). Current: $REQUIRED_SPACE"
    fi
    if ! [[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || [ "$MAX_ATTEMPTS" -lt 1 ]; then
        exit_with_error "MAX_ATTEMPTS must be a positive integer. Current: $MAX_ATTEMPTS"
    fi
    if ! [[ "$SLEEP_SECS" =~ ^[0-9]+$ ]] || [ "$SLEEP_SECS" -lt 0 ]; then
        exit_with_error "SLEEP_SECS must be a non-negative integer. Current: $SLEEP_SECS"
    fi
    if [ "$MAX_ATTEMPTS" -gt 100 ]; then
        exit_with_error "MAX_ATTEMPTS must be at most 100. Current: $MAX_ATTEMPTS"
    fi
    if ! [[ "${CS2_APP_ID:-}" =~ ^[0-9]+$ ]]; then
        exit_with_error "CS2_APP_ID must be a numeric app id (e.g. 730). Current: $CS2_APP_ID"
    fi
}

ensure_logfile_writable() {
    local logdir created_dir
    logdir=$(dirname "$LOGFILE")
    created_dir=0
    if [ ! -d "$logdir" ]; then
        mkdir -p "$logdir" || exit_with_error "Failed to create log directory: $logdir"
        created_dir=1
    fi
    touch "$LOGFILE" 2> /dev/null || exit_with_error "Log file is not writable: $LOGFILE"
    # When running as root and we created the dir or file, allow steam user to write (e.g. shared log).
    # Prefer user:group; fall back to user only if group 'steam' does not exist.
    if [ "${EUID:-$(id -u)}" -eq 0 ] && [ "$ALLOW_NONROOT" != "1" ]; then
        if [ "$created_dir" -eq 1 ]; then
            chown steam:steam "$logdir" 2> /dev/null || chown steam: "$logdir" 2> /dev/null || true
        fi
        chown steam:steam "$LOGFILE" 2> /dev/null || chown steam: "$LOGFILE" 2> /dev/null || true
    fi
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
    # Remove temp file used for SteamCMD output (if any).
    if [ -n "$TMP_UPDATE_OUTPUT" ] && [ -f "$TMP_UPDATE_OUTPUT" ]; then
        rm -f "$TMP_UPDATE_OUTPUT"
        TMP_UPDATE_OUTPUT=""
    fi
    if [ -n "$TMP_GET_REMOTE_BUILDID" ] && [ -f "$TMP_GET_REMOTE_BUILDID" ]; then
        rm -f "$TMP_GET_REMOTE_BUILDID"
        TMP_GET_REMOTE_BUILDID=""
    fi
    # Remove the lock dir only if we created it and it is not a symlink (safety). Idempotent: run once.
    if [ "$CLEANUP_ENABLED" -eq 1 ] && [ -d "$LOCKDIR" ] && [ ! -L "$LOCKDIR" ]; then
        rmdir "$LOCKDIR" 2> /dev/null || rm -rf "$LOCKDIR"
        log "Lock removed."
        CLEANUP_ENABLED=0
    fi
}
trap cleanup EXIT

#### Step 1: Create Lock ####
# Call validate_config before this so LOCKDIR is not a file/symlink.
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
# GNU df --output=avail uses 1024-byte blocks; REQUIRED_SPACE is in KB.
check_space() {
    local avail
    avail=$(df --output=avail "$CS2_DIR" 2> /dev/null | awk 'NR==2 {print $1}')
    if [ -z "$avail" ]; then
        exit_with_error "Failed to determine free disk space for: $CS2_DIR"
    fi
    avail="${avail//[[:space:]]/}"
    if ! [[ "$avail" =~ ^[0-9]+$ ]]; then
        exit_with_error "Invalid disk space value from df: $avail"
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
            # Use a wrapper script to avoid ARG_MAX with long -c command line.
            # Note: arguments must not contain newlines (one argument per line in script).
            local su_script su_ret
            su_script=$(mktemp 2> /dev/null) || exit_with_error "Failed to create temporary file for su wrapper (e.g. /tmp full or not writable)."
            printf '%s\n' "$@" >> "$su_script"
            chmod 644 "$su_script" 2> /dev/null || true
            # shellcheck disable=SC2016
            su -s /bin/bash -c 'cmd=$(head -n1 "$1"); args=(); while IFS= read -r line; do args+=("$line"); done < <(tail -n +2 "$1"); exec "$cmd" "${args[@]}"' steam "$su_script"
            su_ret=$?
            rm -f "$su_script"
            return $su_ret
        fi
        if command -v sudo > /dev/null 2>&1; then
            sudo -u steam "$@"
            return $?
        fi
        exit_with_error "Need one of: runuser, su, sudo (to run SteamCMD as 'steam' user)."
    fi

    exit_with_error "Must run as root or set ALLOW_NONROOT=1 (cannot run as 'steam' user)."
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
    local update_ret
    TMP_UPDATE_OUTPUT=$(mktemp 2> /dev/null) || exit_with_error "Failed to create temporary file (e.g. /tmp full or not writable)."
    log "Running SteamCMD update as 'steam' user..."
    update_ret=0
    run_as_steam "$STEAMCMD" +login anonymous \
        +force_install_dir "$CS2_DIR" \
        +app_update "$CS2_APP_ID" validate +quit > "$TMP_UPDATE_OUTPUT" 2>&1 || update_ret=$?
    log "SteamCMD output:"
    log_multiline "steamcmd: " < "$TMP_UPDATE_OUTPUT"
    rm -f "$TMP_UPDATE_OUTPUT"
    TMP_UPDATE_OUTPUT=""
    if [ "$update_ret" -ne 0 ]; then
        log "Attempting to start $SERVICE_NAME after failed update..."
        start_service || true
        exit_with_error "SteamCMD update failed."
    fi
}

read_buildid() {
    local manifest
    manifest="${CS2_DIR%/}/steamapps/appmanifest_${CS2_APP_ID}.acf"

    if [ ! -f "$manifest" ]; then
        printf ''
        return 0
    fi

    # ACF is key/value; trim key and value for robustness (whitespace, format variants).
    awk -F'"' '
        { gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $4) }
        $2 == "buildid" && $4 != "" { print $4; exit }
    ' "$manifest" 2> /dev/null || true
}

get_remote_buildid() {
    local tmpfile buildid run_ret

    tmpfile=$(mktemp 2> /dev/null) || {
        log "Warning: mktemp failed, cannot get remote buildid; will fall back to safe update if needed."
        printf ''
        return 0
    }
    TMP_GET_REMOTE_BUILDID="$tmpfile"
    run_ret=0
    run_as_steam "$STEAMCMD" +login anonymous +app_info_update 1 +app_info_print "$CS2_APP_ID" +quit > "$tmpfile" 2>&1 || run_ret=$?
    if [ "$run_ret" -ne 0 ]; then
        log "SteamCMD app_info_print failed; output:"
        log_multiline "steamcmd: " < "$tmpfile"
        rm -f "$tmpfile"
        TMP_GET_REMOTE_BUILDID=""
        printf ''
        return 0
    fi

    # Best-effort: find buildid of public branch; fallback to first "buildid" in output (parse from file to avoid large variable).
    buildid=$(
        awk -F'"' '
            /"branches"/ { in_branches=1 }
            in_branches && /"public"/ { in_public=1 }
            in_public && $2=="buildid" && $4 != "" { print $4; exit }
        ' "$tmpfile" 2> /dev/null
    )
    if [ -z "$buildid" ]; then
        buildid=$(awk -F'"' '$2=="buildid" && $4 != "" { print $4; exit }' "$tmpfile" 2> /dev/null)
    fi

    rm -f "$tmpfile"
    TMP_GET_REMOTE_BUILDID=""
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
require_steam_user
validate_config
ensure_logfile_writable
require_cmd awk
require_cmd df
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
