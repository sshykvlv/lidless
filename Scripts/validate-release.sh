#!/bin/bash
set -euo pipefail

readonly EXPECTED_APP_ID="lv.ykv.lidless"
readonly EXPECTED_HELPER_ID="lv.ykv.lidless.helper"
readonly EXPECTED_TEAM_ID="J2Q78NFXZX"
readonly HELPER_RELATIVE_PATH="Contents/Library/HelperTools/LidlessHelper"
readonly DAEMON_RELATIVE_PATH="Contents/Library/LaunchDaemons/lv.ykv.lidless.helper.plist"

fail() {
  echo "Release validation failed: $*" >&2
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

signing_field() {
  local details="$1"
  local field="$2"
  printf '%s\n' "$details" | sed -n "s/^${field}=//p" | head -n 1
}

require_universal() {
  local binary="$1"
  local architectures
  architectures="$(lipo -archs "$binary")"
  case "$architectures" in
    "arm64 x86_64"|"x86_64 arm64") ;;
    *) fail "expected arm64 and x86_64 in $binary, got: $architectures" ;;
  esac
}

require_release_signature() {
  local code="$1"
  local expected_identifier="$2"
  local details
  details="$(codesign -dvvv "$code" 2>&1)"

  [[ "$(signing_field "$details" Identifier)" == "$expected_identifier" ]] \
    || fail "unexpected signing identifier for $code"
  [[ "$(signing_field "$details" TeamIdentifier)" == "$EXPECTED_TEAM_ID" ]] \
    || fail "unexpected Team ID for $code"
  printf '%s\n' "$details" | grep -Eq '^Authority=Developer ID Application:' \
    || fail "Developer ID signature missing for $code"
  printf '%s\n' "$details" | grep -Eq '^CodeDirectory .*flags=.*\(runtime' \
    || fail "hardened runtime missing for $code"
  printf '%s\n' "$details" | grep -Eq '^Timestamp=' \
    || fail "trusted signing timestamp missing for $code"
}

if [[ $# -ne 2 ]]; then
  echo "Usage: Scripts/validate-release.sh APP VERSION" >&2
  exit 64
fi

app="$1"
version="$2"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || fail "version must be strict semantic version"
[[ -d "$app" && ! -L "$app" ]] || fail "app must be a real directory"
app_parent="$(cd "$(dirname "$app")" && pwd -P)"
app="$app_parent/$(basename "$app")"
[[ "$(basename "$app")" == "Lidless.app" ]] || fail "unexpected app name"

readonly INFO_PLIST="$app/Contents/Info.plist"
readonly APP_BINARY="$app/Contents/MacOS/Lidless"
readonly HELPER="$app/$HELPER_RELATIVE_PATH"
readonly DAEMON_PLIST="$app/$DAEMON_RELATIVE_PATH"

[[ -f "$INFO_PLIST" && ! -L "$INFO_PLIST" ]] || fail "unsafe app Info.plist"
[[ -x "$APP_BINARY" && -f "$APP_BINARY" && ! -L "$APP_BINARY" ]] \
  || fail "unsafe app executable"
[[ -x "$HELPER" && -f "$HELPER" && ! -L "$HELPER" ]] || fail "unsafe helper executable"
[[ -f "$DAEMON_PLIST" && ! -L "$DAEMON_PLIST" ]] || fail "unsafe launch daemon plist"

[[ "$(plist_value "$INFO_PLIST" CFBundleShortVersionString)" == "$version" ]] \
  || fail "unexpected marketing version"
[[ "$(plist_value "$INFO_PLIST" CFBundleVersion)" == "$version" ]] \
  || fail "unexpected build version"
[[ "$(plist_value "$INFO_PLIST" CFBundleIdentifier)" == "$EXPECTED_APP_ID" ]] \
  || fail "unexpected bundle identifier"
[[ "$(plist_value "$INFO_PLIST" LSMinimumSystemVersion)" == "13.0" ]] \
  || fail "unexpected minimum macOS version"
if plist_value "$INFO_PLIST" NSAppSleepDisabled >/dev/null; then
  fail "NSAppSleepDisabled must not ship"
fi

plutil -lint "$INFO_PLIST" "$DAEMON_PLIST" >/dev/null
[[ "$(plist_value "$DAEMON_PLIST" Label)" == "$EXPECTED_HELPER_ID" ]] \
  || fail "unexpected launch daemon label"
[[ "$(plist_value "$DAEMON_PLIST" BundleProgram)" == "$HELPER_RELATIVE_PATH" ]] \
  || fail "unexpected launch daemon program"
[[ "$(plist_value "$DAEMON_PLIST" "MachServices:$EXPECTED_HELPER_ID")" == "true" ]] \
  || fail "required Mach service is missing"

require_universal "$APP_BINARY"
require_universal "$HELPER"
codesign --verify --deep --strict --verbose=2 "$app"
codesign --verify --strict --verbose=2 "$HELPER"
require_release_signature "$app" "$EXPECTED_APP_ID"
require_release_signature "$HELPER" "$EXPECTED_HELPER_ID"

if strings "$APP_BINARY" "$HELPER" \
  | rg -n 'AuthorizationExecuteWithPrivileges|/usr/bin/osascript|do shell script|/usr/bin/sudo|/usr/sbin/visudo'; then
  fail "forbidden privilege-escalation string found"
fi

spctl --assess --type execute --verbose=3 "$app"
xcrun stapler validate "$app"
echo "Validated notarized Lidless $version at $app"
