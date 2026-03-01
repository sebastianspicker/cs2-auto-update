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
#   For testing: ALLOW_NONROOT=1 (run as current user), NO_SLEEP=1 (skip sleep between retries).

set -euo pipefail

# Cron can provide a minimal PATH; keep common locations available.
PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}:/usr/games"
export PATH

# Version (match CHANGELOG)
VERSION="1.6.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments (before loading config so --dry-run/--config can be set)
DRY_RUN="${DRY_RUN:-0}"
CLI_DRY_RUN_SET=0
STATUS_ONLY=0
CONFIG_FILE="${CONFIG_FILE:-}"
while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
        -h | --help)
            echo "Usage: $0 [--help|--version|--dry-run|--status|--config=FILE|-c FILE]"
            echo ""
            echo "Updates the CS2 dedicated server via SteamCMD and restarts the service when needed."
            echo "Run as root (e.g. via cron). Key environment variables:"
            echo "  LOCKDIR, LOGFILE, CS2_DIR, SERVICE_NAME, STEAMCMD, CS2_APP_ID"
            echo "  REQUIRED_SPACE (KB), MAX_ATTEMPTS, SLEEP_SECS"
            echo "  ALLOW_NONROOT=1, NO_SLEEP=1 (testing), DRY_RUN=1, LOG_LEVEL=quiet|normal|verbose"
            echo "  CONFIG_FILE (path to config file), NOTIFY_WEBHOOK_URL (webhook on success)"
            echo ""
            echo "Options: --dry-run (check only, no update); --status (print up-to-date or update available, then exit); --config=FILE or -c FILE (config file path)."
            echo "Examples: sudo $0 ; sudo $0 --dry-run ; sudo $0 --status"
            echo "Cron example: 0 7 * * * /home/steam/update_cs2.sh"
            exit 0
            ;;
        -v | --version)
            echo "$VERSION"
            exit 0
            ;;
        --dry-run)
            DRY_RUN=1
            CLI_DRY_RUN_SET=1
            shift
            ;;
        --status)
            STATUS_ONLY=1
            shift
            ;;
        -c)
            if [ $# -lt 2 ]; then
                echo "ERROR: -c requires an argument. Use -c /path/to/config" >&2
                exit 1
            fi
            CONFIG_FILE="$2"
            shift 2
            ;;
        -c=*)
            CONFIG_FILE="${arg#-c=}"
            shift
            ;;
        -c*)
            CONFIG_FILE="${arg#-c}"
            shift
            ;;
        --config=*)
            CONFIG_FILE="${arg#--config=}"
            shift
            ;;
        --config)
            if [ $# -lt 2 ]; then
                echo "ERROR: --config requires an argument. Use --config=/path/to/config" >&2
                exit 1
            fi
            CONFIG_FILE="$2"
            shift 2
            ;;
        -*)
            echo "ERROR: Unknown option: $arg" >&2
            exit 1
            ;;
        *)
            echo "ERROR: Unexpected positional argument: $arg" >&2
            exit 1
            ;;
    esac
done

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

# Apply default when empty (single source of truth; run after config load and after trim).
apply_defaults() {
    local var
    for var in LOCKDIR REQUIRED_SPACE MAX_ATTEMPTS SLEEP_SECS SERVICE_NAME; do
        if [ -z "${!var}" ]; then
            case "$var" in
                LOCKDIR) LOCKDIR="/tmp/update_cs2.lock" ;;
                REQUIRED_SPACE) REQUIRED_SPACE="5000000" ;;
                MAX_ATTEMPTS) MAX_ATTEMPTS="5" ;;
                SLEEP_SECS) SLEEP_SECS="5" ;;
                SERVICE_NAME) SERVICE_NAME="cs2.service" ;;
            esac
        fi
    done
}
apply_defaults

# Testing helper: set to 1 to allow running as non-root (runs SteamCMD as the current user).
ALLOW_NONROOT="${ALLOW_NONROOT:-0}"
NO_SLEEP="${NO_SLEEP:-0}"
# quiet = only ERROR/WARNING; normal = all; verbose = all (future: more detail)
LOG_LEVEL="${LOG_LEVEL:-normal}"
# Optional webhook URL (e.g. Discord/Slack) to notify on successful update; empty = disabled
NOTIFY_WEBHOOK_URL="${NOTIFY_WEBHOOK_URL:-}"

# Single source of truth: config-file whitelist and trim loop use this list.
CONFIG_AND_TRIM_VARS="LOCKDIR LOGFILE CS2_DIR SERVICE_NAME STEAMCMD CS2_APP_ID REQUIRED_SPACE MAX_ATTEMPTS SLEEP_SECS ALLOW_NONROOT NO_SLEEP LOG_LEVEL DRY_RUN NOTIFY_WEBHOOK_URL"

load_config_file() {
    local path line key val allowed
    path="$1"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            # Keep parser portable to older /bin/bash versions (e.g., macOS bash 3.2).
            val="${val//$'\r'/}"
            val="${val//$'\n'/}"
            for allowed in $CONFIG_AND_TRIM_VARS; do
                if [ "$key" = "$allowed" ]; then
                    printf -v "$key" '%s' "$val"
                    break
                fi
            done
        fi
    done < "$path"
}

# Optional config file (same variable names as env); overrides defaults
[ -z "${CONFIG_FILE:-}" ] && CONFIG_FILE="$SCRIPT_DIR/cs2-auto-update.conf"
if [ "$CONFIG_FILE" = "-" ]; then
    echo "ERROR: CONFIG_FILE must not be '-' (stdin)." >&2
    exit 1
fi
if [ -n "$CONFIG_FILE" ] && [[ "$CONFIG_FILE" == -* ]]; then
    echo "ERROR: CONFIG_FILE must not look like an option: $CONFIG_FILE" >&2
    exit 1
fi
if [ -n "$CONFIG_FILE" ] && [[ "$CONFIG_FILE" == *".."* ]]; then
    echo "ERROR: CONFIG_FILE must not contain '..': $CONFIG_FILE" >&2
    exit 1
fi
if [ -n "$CONFIG_FILE" ] && [ -e "$CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: CONFIG_FILE must be a regular file: $CONFIG_FILE" >&2
    exit 1
fi
if [ -f "$CONFIG_FILE" ]; then
    load_config_file "$CONFIG_FILE"
    apply_defaults
fi

# Consolidation: Trim leading/trailing whitespace (same vars as config whitelist).
for var in $CONFIG_AND_TRIM_VARS; do
    # Use variable indirection to get and set values
    val="${!var}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    printf -v "$var" '%s' "$val"
done
apply_defaults

# CLI flags must have highest precedence over config file values.
if [ "$CLI_DRY_RUN_SET" = "1" ]; then
    DRY_RUN=1
fi

#### Internal state ####
CLEANUP_ENABLED=0
TMP_UPDATE_OUTPUT=""
TMP_GET_REMOTE_BUILDID=""
LOCK_PID_FILE=""

#### Helper Functions ####
log() {
    local ts level msg
    if [ "$LOG_LEVEL" = "quiet" ]; then
        case "$*" in
            ERROR:* | *ERROR* | WARNING:* | *WARNING*) ;;
            *) return 0 ;;
        esac
    fi
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    level="INFO"
    case "$*" in
        ERROR:* | *ERROR*) level="ERROR" ;;
        WARNING:* | *WARNING*) level="WARN" ;;
    esac
    msg="[$ts] [$level] $*"

    # Always emit to stdout for journald/cron capture; best-effort append to logfile.
    printf '%s\n' "$msg"
    printf '%s\n' "$msg" >> "$LOGFILE" 2> /dev/null || true
}

# Read from stdin to avoid ARG_MAX when logging large output (e.g. SteamCMD).
# Call only with stdin connected (e.g. log_multiline "prefix" < file or ... | log_multiline "prefix").
log_multiline() {
    local prefix line
    prefix="${1:-}"
    while IFS= read -r line || [ -n "$line" ]; do
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
    if [ "$LOCKDIR" = "/" ] || [[ "$LOCKDIR" =~ ^/+$ ]]; then
        exit_with_error "LOCKDIR must not be root (/). Use a subdirectory, e.g. /tmp/update_cs2.lock"
    fi
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
    if [ "$SLEEP_SECS" -gt 3600 ]; then
        exit_with_error "SLEEP_SECS must be at most 3600 (1 hour). Current: $SLEEP_SECS"
    fi
    if [ "$MAX_ATTEMPTS" -gt 100 ]; then
        exit_with_error "MAX_ATTEMPTS must be at most 100. Current: $MAX_ATTEMPTS"
    fi
    if ! [[ "${CS2_APP_ID:-}" =~ ^[0-9]+$ ]]; then
        exit_with_error "CS2_APP_ID must be a numeric app id (e.g. 730). Current: $CS2_APP_ID"
    fi
    case "${LOG_LEVEL:-}" in
        quiet | normal | verbose) ;;
        *) exit_with_error "LOG_LEVEL must be one of: quiet, normal, verbose. Current: $LOG_LEVEL" ;;
    esac
    if ! [[ "${ALLOW_NONROOT:-}" =~ ^[01]$ ]]; then
        exit_with_error "ALLOW_NONROOT must be 0 or 1. Current: $ALLOW_NONROOT"
    fi
    if ! [[ "${NO_SLEEP:-}" =~ ^[01]$ ]]; then
        exit_with_error "NO_SLEEP must be 0 or 1. Current: $NO_SLEEP"
    fi
    if ! [[ "${DRY_RUN:-}" =~ ^[01]$ ]]; then
        exit_with_error "DRY_RUN must be 0 or 1. Current: $DRY_RUN"
    fi
    if [ "$LOGFILE" = "/" ] || [[ "$LOGFILE" =~ ^/+$ ]]; then
        exit_with_error "LOGFILE must not be root (/). Use a file path, e.g. /home/steam/update_cs2.log"
    fi
    if [[ "$LOGFILE" == *".."* ]]; then
        exit_with_error "LOGFILE must not contain '..': $LOGFILE"
    fi
    if [ -L "$LOGFILE" ]; then
        exit_with_error "LOGFILE must not be a symlink: $LOGFILE"
    fi
    if [ -e "$LOGFILE" ] && [ ! -f "$LOGFILE" ]; then
        exit_with_error "LOGFILE must be a regular file path: $LOGFILE"
    fi
    # Prefer a user or log directory; avoid system paths (e.g. under /etc).
    if [[ "${CS2_DIR:-}" == *".."* ]]; then
        exit_with_error "CS2_DIR must not contain '..': $CS2_DIR"
    fi
    if [ -z "${SERVICE_NAME:-}" ]; then
        exit_with_error "SERVICE_NAME must not be empty."
    fi
    # systemd unit names: alphanumeric, dot, hyphen, underscore, @
    if ! [[ "${SERVICE_NAME}" =~ ^[a-zA-Z0-9_.@-]+$ ]]; then
        exit_with_error "SERVICE_NAME must contain only safe unit name characters [a-zA-Z0-9_.@-]. Current: $SERVICE_NAME"
    fi
    if [[ "${STEAMCMD:-}" == *".."* ]]; then
        exit_with_error "STEAMCMD must not contain '..': $STEAMCMD"
    fi
}

ensure_logfile_writable() {
    local logdir created_dir created_file
    logdir=$(dirname "$LOGFILE")
    created_dir=0
    created_file=0
    if [ ! -d "$logdir" ]; then
        mkdir -p "$logdir" || exit_with_error "Failed to create log directory: $logdir"
        created_dir=1
    fi
    if [ ! -e "$LOGFILE" ]; then
        : > "$LOGFILE" 2> /dev/null || exit_with_error "Failed to create log file: $LOGFILE"
        created_file=1
    fi
    touch "$LOGFILE" 2> /dev/null || exit_with_error "Log file is not writable: $LOGFILE"
    # Only change ownership for paths created in this run, never for pre-existing files.
    if [ "${EUID:-$(id -u)}" -eq 0 ] && [ "$ALLOW_NONROOT" != "1" ]; then
        if [ "$created_dir" -eq 1 ]; then
            chown steam:steam "$logdir" 2> /dev/null || chown steam: "$logdir" 2> /dev/null || true
        fi
        if [ "$created_file" -eq 1 ]; then
            chown steam:steam "$LOGFILE" 2> /dev/null || chown steam: "$LOGFILE" 2> /dev/null || true
        fi
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
    if [ -n "$LOCK_PID_FILE" ] && [ -f "$LOCK_PID_FILE" ]; then
        rm -f "$LOCK_PID_FILE" 2> /dev/null || true
        LOCK_PID_FILE=""
    fi
    # Use a safe prefix for temp file removal if needed or just handle registered ones.
    # Remove the lock dir only if we created it and it is not a symlink (safety). Idempotent: run once.
    if [ "$CLEANUP_ENABLED" -eq 1 ] && [ -d "$LOCKDIR" ] && [ ! -L "$LOCKDIR" ]; then
        if rmdir "$LOCKDIR" 2> /dev/null; then
            log "Lock removed."
        else
            log "WARNING: Could not remove lock directory (non-empty?). Remove manually if needed: $LOCKDIR"
        fi
        CLEANUP_ENABLED=0
    fi
}
trap cleanup EXIT

#### Step 1: Create Lock ####
# Call validate_config before this so LOCKDIR is not a file/symlink.
path_owner_uid() {
    local path owner
    path="$1"
    owner=""
    owner=$(stat -c '%u' "$path" 2> /dev/null || true)
    if [ -n "$owner" ]; then
        printf '%s' "$owner"
        return 0
    fi
    owner=$(stat -f '%u' "$path" 2> /dev/null || true)
    if [ -n "$owner" ]; then
        printf '%s' "$owner"
        return 0
    fi
    printf ''
}

pid_exists() {
    local pid
    pid="$1"
    kill -0 "$pid" 2> /dev/null || ps -p "$pid" > /dev/null 2>&1
}

write_lock_pid() {
    LOCK_PID_FILE="${LOCKDIR%/}/pid"
    printf '%s\n' "$$" > "$LOCK_PID_FILE" || exit_with_error "Failed to write lock PID file: $LOCK_PID_FILE"
}

init_lock() {
    local owner_uid current_uid lock_pid_file lock_pid
    current_uid="${EUID:-$(id -u)}"

    # mkdir is atomic; avoids races when two instances start simultaneously.
    if mkdir "$LOCKDIR" 2> /dev/null; then
        CLEANUP_ENABLED=1
        write_lock_pid
        log "Lock acquired."
        return 0
    fi

    if [ -d "$LOCKDIR" ]; then
        owner_uid="$(path_owner_uid "$LOCKDIR")"
        if [ -n "$owner_uid" ] && [ "$owner_uid" != "$current_uid" ]; then
            exit_with_error "Lock directory exists but is owned by uid $owner_uid (current uid $current_uid). Refusing to trust it: $LOCKDIR"
        fi

        lock_pid_file="${LOCKDIR%/}/pid"
        if [ -f "$lock_pid_file" ]; then
            lock_pid="$(awk 'NR==1{print; exit}' "$lock_pid_file" 2> /dev/null || true)"
            lock_pid="${lock_pid//[[:space:]]/}"
            if [[ "$lock_pid" =~ ^[0-9]+$ ]] && pid_exists "$lock_pid"; then
                log "An update process is already running (lock: $LOCKDIR, pid: $lock_pid). Exiting."
                exit 0
            fi

            log "WARNING: Stale lock detected (pid ${lock_pid:-unknown} not running). Attempting recovery..."
            rm -f "$lock_pid_file" || exit_with_error "Failed to remove stale lock PID file: $lock_pid_file"
            if rmdir "$LOCKDIR" 2> /dev/null; then
                if mkdir "$LOCKDIR" 2> /dev/null; then
                    CLEANUP_ENABLED=1
                    write_lock_pid
                    log "Recovered stale lock and acquired a new lock."
                    return 0
                fi
                exit_with_error "Recovered stale lock but failed to re-acquire lock: $LOCKDIR"
            fi
            exit_with_error "Stale lock detected but lock directory is not empty; remove manually: $LOCKDIR"
        fi
        log "An update process is already running (lock: $LOCKDIR). Exiting."
        exit 0
    fi

    exit_with_error "Failed to create lock directory: $LOCKDIR"
}

#### Step 2: Check Disk Space ####
# GNU df --output=avail uses 1024-byte blocks; REQUIRED_SPACE is in KB.
check_space() {
    local avail
    if df --version 2>&1 | grep -q "GNU coreutils"; then
        avail=$(df --output=avail "$CS2_DIR" 2> /dev/null | awk 'NR==2 {print $1}')
    else
        # Fallback for non-GNU df (macos/bsd/busybox). Result is in blocks;
        # usually 512-byte blocks or 1K depending on flags. Column layout is OS-dependent;
        # NF-2 is typically "Available" for 1K-block output.
        avail=$(df -k "$CS2_DIR" 2> /dev/null | awk 'NR==2 {print $(NF-2)}')
    fi
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
            # Safe su call: use printf to avoid expansion issues and pass via stdin or -c
            # but su -c doesn't allow easy argument passing.
            # We use a more robust way: wrap the command in a bash -c with quoted arguments.
            local cmd_str
            cmd_str=$(printf "%q " "$@")
            su -s /bin/bash -c "$cmd_str" steam
            return $?
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
    TMP_UPDATE_OUTPUT=$(mktemp "${TMPDIR:-/tmp}/cs2_update.XXXXXX") || exit_with_error "Failed to create temporary file."
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

    tmpfile=$(mktemp "${TMPDIR:-/tmp}/cs2_appinfo.XXXXXX") || {
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

#### Notify (optional webhook) ####
# Validate webhook URL to prevent SSRF: allow only https or localhost http.
validate_webhook_url() {
    local url
    url="$1"
    if [ -z "$url" ]; then
        return 0
    fi
    if [[ "$url" =~ ^https:// ]]; then
        return 0
    fi
    if [[ "$url" =~ ^http://(127\.0\.0\.1|localhost)(/|:|$) ]]; then
        return 0
    fi
    return 1
}

notify_webhook() {
    local url payload escaped_payload
    url="$1"
    payload="${2:-CS2 server updated successfully.}"
    if [ -z "$url" ]; then
        return 0
    fi
    if ! validate_webhook_url "$url"; then
        log "WARNING: NOTIFY_WEBHOOK_URL must be https:// or http://127.0.0.1|localhost. Skipping webhook."
        return 0
    fi

    # Basic JSON double-quote escaping (payload is fixed in current use; extend if made dynamic)
    escaped_payload="${payload//\"/\\\"}"

    if command -v curl > /dev/null 2>&1; then
        if curl -fsS -X POST -H "Content-Type: application/json" \
            -d "{\"text\":\"$escaped_payload\"}" "$url" > /dev/null 2>&1; then
            log "Webhook notification sent."
        else
            log "WARNING: Webhook request failed (non-fatal)."
        fi
    else
        log "WARNING: curl not found; skipping webhook (non-fatal)."
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

UPDATE_START_TIME=$(date +%s)
log "=== Update process initiated ==="
init_lock
check_space

BUILDID_BEFORE=$(read_buildid)
log "Detected buildid before update: ${BUILDID_BEFORE:-unknown}"

REMOTE_BUILDID=$(get_remote_buildid)
log "Detected remote buildid: ${REMOTE_BUILDID:-unknown}"

if [ "$STATUS_ONLY" = "1" ]; then
    if [ -n "$BUILDID_BEFORE" ] && [ -n "$REMOTE_BUILDID" ] && [ "$BUILDID_BEFORE" = "$REMOTE_BUILDID" ]; then
        log "Status: up-to-date (buildid $BUILDID_BEFORE)"
    else
        log "Status: update available (local ${BUILDID_BEFORE:-unknown}, remote ${REMOTE_BUILDID:-unknown})"
    fi
    log "=== Update process completed (status only, $(($(date +%s) - UPDATE_START_TIME))s) ==="
    exit 0
fi

if [ -n "$BUILDID_BEFORE" ] && [ -n "$REMOTE_BUILDID" ] && [ "$BUILDID_BEFORE" = "$REMOTE_BUILDID" ]; then
    log "No update required (local buildid matches remote)."
    ensure_service_running
    log "=== Update process completed ($(($(date +%s) - UPDATE_START_TIME))s) ==="
    exit 0
fi

if [ -n "$BUILDID_BEFORE" ] && [ -n "$REMOTE_BUILDID" ] && [ "$BUILDID_BEFORE" != "$REMOTE_BUILDID" ]; then
    log "Update required (local buildid differs from remote)."
else
    log "Unable to determine update requirement reliably; falling back to safe update run."
fi

if [ "$DRY_RUN" = "1" ]; then
    log "Dry run: skipping service stop, SteamCMD update, and service start."
    log "=== Update process completed (dry run, $(($(date +%s) - UPDATE_START_TIME))s) ==="
    exit 0
fi

stop_service
run_update

BUILDID_AFTER=$(read_buildid)
log "Detected buildid after update: ${BUILDID_AFTER:-unknown}"

start_service

if [ -n "${NOTIFY_WEBHOOK_URL:-}" ]; then
    notify_webhook "$NOTIFY_WEBHOOK_URL" "CS2 server updated successfully."
fi

log "=== Update process completed ($(($(date +%s) - UPDATE_START_TIME))s) ==="
exit 0
