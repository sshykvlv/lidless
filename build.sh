#!/bin/bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "$0")" && pwd)"
readonly BUILD_ROOT="$ROOT/.build"
readonly PROJECT="$BUILD_ROOT/Lidless.xcodeproj"
readonly DERIVED_DATA="$BUILD_ROOT/DerivedData"
readonly APP_NAME="Lidless.app"
readonly EXPECTED_TEAM_ID="J2Q78NFXZX"
readonly EXPECTED_APP_ID="lv.ykv.lidless"
readonly EXPECTED_HELPER_ID="lv.ykv.lidless.helper"

require_plist_value() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    local actual

    if ! actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)"; then
        echo "Missing required Info.plist key: $key" >&2
        return 1
    fi
    if [[ "$actual" != "$expected" ]]; then
        echo "Unexpected Info.plist value for $key: expected '$expected', got '$actual'" >&2
        return 1
    fi
}

codesign_field() {
    local binary="$1"
    local field="$2"
    codesign -dv --verbose=4 "$binary" 2>&1 \
        | sed -n "s/^${field}=//p" \
        | head -n 1
}

require_codesign_field() {
    local binary="$1"
    local field="$2"
    local expected="$3"
    local actual
    actual="$(codesign_field "$binary" "$field")"
    if [[ "$actual" != "$expected" ]]; then
        echo "Unexpected $field for $binary: expected '$expected', got '$actual'" >&2
        return 1
    fi
}

generate_project() {
    mkdir -p "$BUILD_ROOT"
    xcodegen generate --spec "$ROOT/project.yml" --project "$BUILD_ROOT"
}

run_tests() {
    generate_project
    xcodebuild \
        -project "$PROJECT" \
        -scheme Lidless \
        -derivedDataPath "$DERIVED_DATA" \
        -destination "platform=macOS" \
        -quiet \
        CODE_SIGNING_ALLOWED=NO \
        "$@" \
        test
}

build_app() {
    local configuration="${1:-Release}"
    generate_project
    xcodebuild \
        -project "$PROJECT" \
        -scheme Lidless \
        -configuration "$configuration" \
        -derivedDataPath "$DERIVED_DATA" \
        -destination "generic/platform=macOS" \
        -quiet \
        ARCHS="arm64 x86_64" \
        ONLY_ACTIVE_ARCH=NO \
        build

    local product="$DERIVED_DATA/Build/Products/$configuration/$APP_NAME"
    local staged="$ROOT/.Lidless.app.staged"
    test -d "$product"
    test -x "$product/Contents/Library/HelperTools/LidlessHelper"

    rm -rf "$staged"
    ditto "$product" "$staged"
    lipo "$staged/Contents/MacOS/Lidless" -verify_arch arm64 x86_64
    lipo "$staged/Contents/Library/HelperTools/LidlessHelper" -verify_arch arm64 x86_64
    require_plist_value "$staged/Contents/Info.plist" CFBundleShortVersionString 1.1.0
    require_plist_value "$staged/Contents/Info.plist" CFBundleVersion 1.1.0
    require_plist_value "$staged/Contents/Info.plist" LSUIElement true
    test -f "$staged/Contents/Resources/AppIcon.icns"
    plutil -lint "$staged/Contents/Library/LaunchDaemons/lv.ykv.lidless.helper.plist" >/dev/null
    if /usr/libexec/PlistBuddy -c 'Print :NSAppSleepDisabled' "$staged/Contents/Info.plist" >/dev/null 2>&1; then
        echo "NSAppSleepDisabled must not be present; Lidless uses a scoped activity instead" >&2
        exit 1
    fi
    codesign --verify --deep --strict "$staged"
    require_codesign_field "$staged" Identifier "$EXPECTED_APP_ID"
    require_codesign_field "$staged" TeamIdentifier "$EXPECTED_TEAM_ID"
    require_codesign_field "$staged/Contents/Library/HelperTools/LidlessHelper" Identifier "$EXPECTED_HELPER_ID"
    require_codesign_field "$staged/Contents/Library/HelperTools/LidlessHelper" TeamIdentifier "$EXPECTED_TEAM_ID"
    if nm -gj "$staged/Contents/Library/HelperTools/LidlessHelper" \
        | grep -E '(^|_)system$|(^|_)popen$|AuthorizationExecuteWithPrivileges' >/dev/null; then
        echo "LidlessHelper contains a forbidden generic execution entry point" >&2
        return 1
    fi

    rm -rf "$ROOT/$APP_NAME"
    mv "$staged" "$ROOT/$APP_NAME"
    echo "Built universal $configuration $ROOT/$APP_NAME"
}

clean_build() {
    rm -rf "$BUILD_ROOT" "$ROOT/.Lidless.app.staged" "$ROOT/$APP_NAME"
}

command="${1:-app}"
if [[ $# -gt 0 ]]; then
    shift
fi

case "$command" in
    test) run_tests "$@" ;;
    app) build_app Release ;;
    smoke-app) build_app Debug ;;
    clean) clean_build ;;
    *)
        echo "Usage: $0 {test|app|smoke-app|clean} [xcodebuild test arguments]" >&2
        exit 64
        ;;
esac
