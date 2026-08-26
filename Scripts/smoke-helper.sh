#!/bin/bash
set -euo pipefail

readonly APP="/Applications/Lidless.app"
readonly APP_BINARY="$APP/Contents/MacOS/Lidless"
readonly HELPER_LABEL="system/lv.ykv.lidless.helper"
readonly ROOT="$(cd "$(dirname "$0")/.." && pwd)"

smoke_dir="$(mktemp -d)"
readonly CONTROL="$smoke_dir/LidlessSmokeControl"
readonly UNSIGNED_PROBE="$smoke_dir/UnsignedHelperProbe"

read_sleep_disabled() {
    /usr/bin/pmset -g | awk 'tolower($1)=="sleepdisabled" {print $2}'
}

wait_for_value() {
    local expected="$1"
    local timeout="$2"
    local started
    started="$(date +%s)"
    while [[ "$(read_sleep_disabled)" != "$expected" ]]; do
        if (( $(date +%s) - started >= timeout )); then
            echo "Timed out waiting for SleepDisabled=$expected" >&2
            return 1
        fi
        sleep 0.2
    done
}

post() {
    "$CONTROL" "$@"
}

ensure_app_running() {
    if ! pgrep -x Lidless >/dev/null; then
        /usr/bin/open -n "$APP"
    fi
    local started
    started="$(date +%s)"
    while ! pgrep -x Lidless >/dev/null; do
        if (( $(date +%s) - started >= 10 )); then
            echo "Lidless did not launch" >&2
            return 1
        fi
        sleep 0.2
    done
    sleep 1
}

restore_on_exit() {
    local smoke_exit="$?"
    trap - EXIT
    set +e
    post clear-battery
    post disarm
    wait_for_value 0 35
    ensure_app_running
    rm -rf -- "$smoke_dir"
    exit "$smoke_exit"
}
trap restore_on_exit EXIT

baseline="$(read_sleep_disabled)"
test "$baseline" = 0
test -d "$APP"
test -x "$APP_BINARY"
strings "$APP_BINARY" | grep -q 'lv.ykv.lidless.debug.smoke'
launchctl print "$HELPER_LABEL" >/dev/null

xcrun swiftc -target arm64-apple-macos13.0 "$ROOT/Tests/Fixtures/SmokeControl.swift" -o "$CONTROL"
xcrun swiftc -target arm64-apple-macos13.0 "$ROOT/Tests/Fixtures/UnsignedHelperProbe.swift" -o "$UNSIGNED_PROBE"
ensure_app_running
echo "baseline=$baseline helper=$HELPER_LABEL debug_hooks=present"

post arm
wait_for_value 1 10
post disarm
wait_for_value 0 10
echo "scenario=arm_disarm status=ok"

post arm
wait_for_value 1 10
post battery 11
wait_for_value 1 10
post battery 10
wait_for_value 0 10
post clear-battery
echo "scenario=battery_11_to_10 status=ok"

post arm
wait_for_value 1 10
app_pid="$(pgrep -x Lidless | head -n 1)"
kill -TERM "$app_pid"
wait_for_value 0 35
ensure_app_running
echo "scenario=term_recovery status=ok"

post arm
wait_for_value 1 10
app_pid="$(pgrep -x Lidless | head -n 1)"
kill -KILL "$app_pid"
wait_for_value 0 35
ensure_app_running
echo "scenario=kill_recovery status=ok"

post arm
wait_for_value 1 10
if launchctl kill SIGKILL "$HELPER_LABEL"; then
    wait_for_value 0 35
    launchctl print "$HELPER_LABEL" >/dev/null
    echo "scenario=helper_restart status=ok"
else
    echo "scenario=helper_restart status=requires_privileged_terminal" >&2
    exit 77
fi

ensure_app_running
post arm
wait_for_value 1 10
post quit
wait_for_value 0 10
ensure_app_running
echo "scenario=normal_quit status=ok"

"$UNSIGNED_PROBE"
test "$(read_sleep_disabled)" = 0
echo "scenario=unsigned_client_rejected status=ok"

post invalid-version
sleep 1
test "$(read_sleep_disabled)" = 0
echo "scenario=invalid_protocol_rejected status=ok"

echo "smoke=passed baseline=$baseline final=$(read_sleep_disabled)"
