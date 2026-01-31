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

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

export PATH="$PWD/tests/bin:$PATH"

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
    local name local_build remote_build update_exit
    name="$1"
    local_build="$2"
    remote_build="$3"
    update_exit="$4" # 0 or 1

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

    export REMOTE_BUILDID="$remote_build"
    export STEAMCMD_UPDATE_EXIT="$update_exit"

    export SYSTEMCTL_CALLS_FILE="$tmpdir/systemctl.calls"
    export SYSTEMCTL_STATE_FILE="$tmpdir/systemctl.state"
    echo "active" > "$SYSTEMCTL_STATE_FILE"

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
        *)
            fail "unknown case: $name"
            ;;
    esac
}

run_case "no-update" "100" "100" "0"
run_case "update-applied" "100" "200" "0"
run_case "update-failed" "100" "200" "1"

echo "OK"
