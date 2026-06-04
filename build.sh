#!/bin/bash
# Собирает Lidless.app (universal: arm64 + x86_64, min macOS 13) без Xcode-проекта.
set -euo pipefail
cd "$(dirname "$0")"

APP="Lidless.app"
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build
cp Info.plist "$APP/Contents/Info.plist"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

FRAMEWORKS=(-framework Cocoa -framework ServiceManagement -framework IOKit)
for arch in arm64 x86_64; do
    swiftc -O main.swift -target "${arch}-apple-macos13.0" \
        -o "build/Lidless-${arch}" "${FRAMEWORKS[@]}"
done
lipo -create build/Lidless-arm64 build/Lidless-x86_64 -output "$APP/Contents/MacOS/Lidless"
rm -rf build

# ad-hoc подпись для локального запуска (release.sh переподпишет Developer ID)
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✅ Собрано (universal): $APP"
lipo -archs "$APP/Contents/MacOS/Lidless"
