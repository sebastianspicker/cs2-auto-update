#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local needle haystack
    needle="$1"
    haystack="$2"
    if ! grep -Fq "$needle" <<< "$haystack"; then
        fail "Expected to find '$needle' in: $haystack"
    fi
}

assert_not_contains() {
    local needle haystack
    needle="$1"
    haystack="$2"
    if grep -Fq "$needle" <<< "$haystack"; then
        fail "Expected NOT to find '$needle' in: $haystack"
    fi
}

# Run script, assert exit code and that combined output contains needle. Pass env overrides as KEY=val.
# Baseline env is reset each time so tests do not inherit from previous runs.
run_validation_test() {
    local name expected_rc needle pair key val
    name="$1"
    expected_rc="$2"
    needle="$3"
    shift 3
    export LOCKDIR="$tmpdir/lock"
    export LOGFILE="$tmpdir/log"
    export CS2_DIR="$tmpdir/cs2"
    export SERVICE_NAME="cs2.service"
    export SLEEP_SECS="0"
    export ALLOW_NONROOT="1"
    export NO_SLEEP="1"
    export LOG_LEVEL="normal"
    export DRY_RUN="0"
    export CONFIG_FILE=""
    for pair in "$@"; do
        key="${pair%%=*}"
        val="${pair#*=}"
        export "$key"="$val"
    done
    echo "==> $name"
    set +e
    ./update_cs2.sh > "$tmpdir/stdout" 2> "$tmpdir/stderr"
    rc=$?
    set -e
    [ "$rc" -eq "$expected_rc" ] || fail "expected rc=$expected_rc, got $rc; stderr=$(cat "$tmpdir/stderr")"
    assert_contains "$needle" "$(cat "$tmpdir/stdout" "$tmpdir/stderr")"
}

tmpdir="$(mktemp -d ./tmp.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

# Create a mock df that supports --version and -k
cat > "$tmpdir/df" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
    echo "df (mock)"
    exit 0
fi
# Just return a dummy value
echo "Filesystem 1K-blocks Used Available Use% Mounted on"
echo "/dev/mock 1000000 500000 500000 50% /"
EOF
chmod +x "$tmpdir/df"

export PATH="$tmpdir:$PWD/tests/bin:$PATH"

setup_cs2_dir() {
    local buildid
    buildid="$1"
    mkdir -p "$tmpdir/cs2/steamapps"
    cat > "$tmpdir/cs2/steamapps/appmanifest_730.acf" << EOF
"AppState"
{
    "appid"  "730"
    "buildid"    "$buildid"
}
EOF
}

run_case() {
    local name local_build remote_build update_exit initial_state
    name="$1"
    local_build="$2"
    remote_build="$3"
    update_exit="$4" # 0 or 1
    initial_state="${5:-active}"

    echo "==> $name"

    rm -rf "$tmpdir/cs2" "$tmpdir/lock" "$tmpdir/log" "$tmpdir/systemctl.calls" "$tmpdir/systemctl.state"
    setup_cs2_dir "$local_build"

    export LOCKDIR="$tmpdir/lock"
    export LOGFILE="$tmpdir/log"
    export CS2_DIR="$tmpdir/cs2"
    export SERVICE_NAME="cs2.service"
    export STEAMCMD="$PWD/tests/bin/steamcmd"
    export CS2_APP_ID="730"
    export REQUIRED_SPACE="1"
    export MAX_ATTEMPTS="1"
    export SLEEP_SECS="0"
    export NO_SLEEP="1"
    export ALLOW_NONROOT="1"
    export CONFIG_FILE="$tmpdir/nonexistent.conf"

    export REMOTE_BUILDID="$remote_build"
    export STEAMCMD_UPDATE_EXIT="$update_exit"

    export SYSTEMCTL_CALLS_FILE="$tmpdir/systemctl.calls"
    export SYSTEMCTL_STATE_FILE="$tmpdir/systemctl.state"
    echo "$initial_state" > "$SYSTEMCTL_STATE_FILE"

    set +e
    ./update_cs2.sh > "$tmpdir/stdout" 2> "$tmpdir/stderr"
    rc=$?
    set -e

    calls=""
    if [ -f "$SYSTEMCTL_CALLS_FILE" ]; then
        calls="$(cat "$SYSTEMCTL_CALLS_FILE")"
    fi

    stdout="$(cat "$tmpdir/stdout")"
    stderr="$(cat "$tmpdir/stderr")"

    case "$name" in
        "no-update")
            [ "$rc" -eq 0 ] || fail "expected rc=0, got $rc; stderr=$stderr"
            assert_contains "No update required" "$stdout"
            assert_not_contains "stop" "$calls"
            assert_not_contains "start" "$calls"
            ;;
        "update-applied")
            [ "$rc" -eq 0 ] || fail "expected rc=0, got $rc; stderr=$stderr"
            assert_contains "Update required" "$stdout"
            assert_contains "stop" "$calls"
            assert_contains "start" "$calls"
            ;;
        "update-failed")
            [ "$rc" -ne 0 ] || fail "expected non-zero rc, got $rc"
            assert_contains "SteamCMD update failed" "$stdout"
            assert_contains "stop" "$calls"
            assert_contains "start" "$calls"
            ;;
        "fallback-update")
            [ "$rc" -eq 0 ] || fail "expected rc=0, got $rc; stderr=$stderr"
            assert_contains "falling back to safe update run" "$stdout"
            assert_contains "stop" "$calls"
            assert_contains "start" "$calls"
            ;;
        "no-update-service-inactive")
            [ "$rc" -eq 0 ] || fail "expected rc=0, got $rc; stderr=$stderr"
            assert_contains "No update required" "$stdout"
            assert_contains "not running; starting" "$stdout"
            assert_not_contains "stop" "$calls"
            assert_contains "start" "$calls"
            ;;
        *)
            fail "unknown case: $name"
            ;;
    esac
}

run_with_args_case() {
    local name expected_rc args initial_state
    name="$1"
    expected_rc="$2"
    args="$3"
    initial_state="${4:-active}"

    echo "==> $name"

    rm -rf "$tmpdir/cs2" "$tmpdir/lock" "$tmpdir/log" "$tmpdir/systemctl.calls" "$tmpdir/systemctl.state"
    setup_cs2_dir "100"

    export LOCKDIR="$tmpdir/lock"
    export LOGFILE="$tmpdir/log"
    export CS2_DIR="$tmpdir/cs2"
    export SERVICE_NAME="cs2.service"
    export STEAMCMD="$PWD/tests/bin/steamcmd"
    export CS2_APP_ID="730"
    export REQUIRED_SPACE="1"
    export MAX_ATTEMPTS="1"
    export SLEEP_SECS="0"
    export NO_SLEEP="1"
    export ALLOW_NONROOT="1"
    export CONFIG_FILE=""
    export REMOTE_BUILDID="200"
    export STEAMCMD_UPDATE_EXIT="0"
    export SYSTEMCTL_CALLS_FILE="$tmpdir/systemctl.calls"
    export SYSTEMCTL_STATE_FILE="$tmpdir/systemctl.state"
    echo "$initial_state" > "$SYSTEMCTL_STATE_FILE"

    set +e
    # shellcheck disable=SC2086
    ./update_cs2.sh $args > "$tmpdir/stdout" 2> "$tmpdir/stderr"
    rc=$?
    set -e
    [ "$rc" -eq "$expected_rc" ] || fail "expected rc=$expected_rc, got $rc; stderr=$(cat "$tmpdir/stderr")"
}

run_lock_case() {
    local name prepare_fn expected_rc needle
    name="$1"
    prepare_fn="$2"
    expected_rc="$3"
    needle="$4"

    echo "==> $name"

    rm -rf "$tmpdir/cs2" "$tmpdir/lock" "$tmpdir/log" "$tmpdir/systemctl.calls" "$tmpdir/systemctl.state"
    setup_cs2_dir "100"

    export LOCKDIR="$tmpdir/lock"
    export LOGFILE="$tmpdir/log"
    export CS2_DIR="$tmpdir/cs2"
    export SERVICE_NAME="cs2.service"
    export STEAMCMD="$PWD/tests/bin/steamcmd"
    export CS2_APP_ID="730"
    export REQUIRED_SPACE="1"
    export MAX_ATTEMPTS="1"
    export SLEEP_SECS="0"
    export NO_SLEEP="1"
    export ALLOW_NONROOT="1"
    export CONFIG_FILE=""
    export REMOTE_BUILDID="100"
    export STEAMCMD_UPDATE_EXIT="0"
    export SYSTEMCTL_CALLS_FILE="$tmpdir/systemctl.calls"
    export SYSTEMCTL_STATE_FILE="$tmpdir/systemctl.state"
    echo "active" > "$SYSTEMCTL_STATE_FILE"

    "$prepare_fn"

    set +e
    ./update_cs2.sh > "$tmpdir/stdout" 2> "$tmpdir/stderr"
    rc=$?
    set -e
    [ "$rc" -eq "$expected_rc" ] || fail "expected rc=$expected_rc, got $rc; stderr=$(cat "$tmpdir/stderr")"
    assert_contains "$needle" "$(cat "$tmpdir/stdout" "$tmpdir/stderr")"
}

prepare_stale_lock_with_dead_pid() {
    mkdir -p "$tmpdir/lock"
    printf '999999\n' > "$tmpdir/lock/pid"
}

run_case "no-update" "100" "100" "0"
run_case "update-applied" "100" "200" "0"
run_case "update-failed" "100" "200" "1"
run_case "fallback-update" "100" "" "0"
run_case "no-update-service-inactive" "100" "100" "0" "inactive"
run_lock_case "stale-lock-recovery" "prepare_stale_lock_with_dead_pid" 0 "Recovered stale lock and acquired a new lock."

# Validation tests (reject bad config or expect normalized success)
run_validation_test "reject LOCKDIR=/" 1 "LOCKDIR must not be root" LOCKDIR="/" LOGFILE="$tmpdir/log" CS2_DIR="$tmpdir/cs2"
run_validation_test "reject LOCKDIR create failure" 1 "Failed to create lock directory" LOCKDIR="$tmpdir/no-write-parent/lock"

run_validation_test "reject invalid SERVICE_NAME" 1 "SERVICE_NAME must contain only safe" SERVICE_NAME="cs2;evil"

run_validation_test "reject SLEEP_SECS > 3600" 1 "SLEEP_SECS must be at most 3600" SLEEP_SECS="5000"
run_validation_test "reject invalid LOG_LEVEL" 1 "LOG_LEVEL must be one of" LOG_LEVEL="loud"
run_validation_test "reject invalid NO_SLEEP" 1 "NO_SLEEP must be 0 or 1" NO_SLEEP="yes"
run_validation_test "reject invalid DRY_RUN" 1 "DRY_RUN must be 0 or 1" DRY_RUN="maybe"

run_validation_test "reject LOGFILE=/" 1 "LOGFILE must not be root" LOGFILE="/" SLEEP_SECS="0"
run_validation_test "reject LOGFILE non-regular" 1 "LOGFILE must be a regular file path" LOGFILE="/dev/null"

# LOGFILE must not be a symlink (avoid writing to symlink target)
touch "$tmpdir/logtarget"
ln -sf "$tmpdir/logtarget" "$tmpdir/loglink"
run_validation_test "reject LOGFILE symlink" 1 "LOGFILE must not be a symlink" LOGFILE="$(cd "$tmpdir" && pwd)/loglink"

run_validation_test "reject CONFIG_FILE=-" 1 "must not be '-'" CONFIG_FILE="-"
run_validation_test "reject CONFIG_FILE like option" 1 "must not look like an option" CONFIG_FILE="--dry-run"

# Empty SERVICE_NAME normalized to default (expect success)
run_validation_test "empty SERVICE_NAME normalized" 0 "Update process" SERVICE_NAME=""
# Normalization yields success; assert exit 0 already done by helper; needle "Update process" in stdout

# CLI --dry-run must win over config DRY_RUN=0 (safety).
cat > "$tmpdir/conf" << 'EOF'
DRY_RUN=0
EOF
run_with_args_case "dry-run CLI overrides config" 0 "--dry-run --config=$tmpdir/conf"
assert_contains "Dry run: skipping service stop, SteamCMD update, and service start." "$(cat "$tmpdir/stdout")"
assert_not_contains "stop" "$(cat "$tmpdir/systemctl.calls" 2> /dev/null || true)"
assert_not_contains "start" "$(cat "$tmpdir/systemctl.calls" 2> /dev/null || true)"

# Unknown options should fail fast to avoid silent misconfiguration.
run_with_args_case "reject unknown option" 1 "--does-not-exist"
assert_contains "Unknown option" "$(cat "$tmpdir/stdout" "$tmpdir/stderr")"

echo "OK"
