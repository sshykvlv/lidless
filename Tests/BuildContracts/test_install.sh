#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

test -x ./install.sh
test -d Lidless.app || ./build.sh app

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
applications_dir="$test_root/Applications"
destination="$applications_dir/Lidless.app"
mkdir -p "$destination"
touch "$destination/previous-version"

./install.sh \
    --destination "$destination" \
    --use-existing-build \
    --no-launch

test -x "$destination/Contents/MacOS/Lidless"
test -x "$destination/Contents/Library/HelperTools/LidlessHelper"
codesign --verify --deep --strict "$destination"

backup_count="$(find "$applications_dir" -maxdepth 1 -type d -name 'Lidless.app.backup-*' | wc -l | tr -d ' ')"
test "$backup_count" = "1"
backup_path="$(find "$applications_dir" -maxdepth 1 -type d -name 'Lidless.app.backup-*' -print -quit)"
test -f "$backup_path/previous-version"
