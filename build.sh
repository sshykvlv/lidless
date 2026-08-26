#!/bin/bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "$0")" && pwd)"
readonly BUILD_ROOT="$ROOT/.build"
readonly PROJECT="$BUILD_ROOT/Lidless.xcodeproj"
readonly DERIVED_DATA="$BUILD_ROOT/DerivedData"
readonly APP_NAME="Lidless.app"

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
    generate_project
    xcodebuild \
        -project "$PROJECT" \
        -scheme Lidless \
        -configuration Release \
        -derivedDataPath "$DERIVED_DATA" \
        -destination "generic/platform=macOS" \
        -quiet \
        ARCHS="arm64 x86_64" \
        ONLY_ACTIVE_ARCH=NO \
        build

    local product="$DERIVED_DATA/Build/Products/Release/$APP_NAME"
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
    if /usr/libexec/PlistBuddy -c 'Print :NSAppSleepDisabled' "$staged/Contents/Info.plist" >/dev/null 2>&1; then
        echo "NSAppSleepDisabled must not be present; Lidless uses a scoped activity instead" >&2
        exit 1
    fi
    codesign --verify --deep --strict "$staged"

    rm -rf "$ROOT/$APP_NAME"
    mv "$staged" "$ROOT/$APP_NAME"
    echo "Built universal $ROOT/$APP_NAME"
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
    app) build_app ;;
    clean) clean_build ;;
    *)
        echo "Usage: $0 {test|app|clean} [xcodebuild test arguments]" >&2
        exit 64
        ;;
esac
