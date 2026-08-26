#!/bin/bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "$0")" && pwd)"
readonly SOURCE_APP="$ROOT/Lidless.app"
readonly EXPECTED_TEAM_ID="J2Q78NFXZX"
readonly EXPECTED_BUNDLE_ID="lv.ykv.lidless"
readonly EXPECTED_HELPER_ID="lv.ykv.lidless.helper"

destination="/Applications/Lidless.app"
build_first=true
launch_after_install=true

usage() {
    cat <<'USAGE'
Usage: ./install.sh [options]

Options:
  --destination PATH       Install to PATH (must end in Lidless.app)
  --use-existing-build     Install the existing ./Lidless.app
  --no-launch              Do not open Lidless after installation
  -h, --help               Show this help
USAGE
}

team_identifier() {
    codesign -dv --verbose=4 "$1" 2>&1 \
        | sed -n 's/^TeamIdentifier=//p' \
        | head -n 1
}

signing_identifier() {
    codesign -dv --verbose=4 "$1" 2>&1 \
        | sed -n 's/^Identifier=//p' \
        | head -n 1
}

validate_bundle() {
    local app="$1"
    local helper="$app/Contents/Library/HelperTools/LidlessHelper"
    local daemon_plist="$app/Contents/Library/LaunchDaemons/lv.ykv.lidless.helper.plist"
    local bundle_id

    test -d "$app"
    test -x "$app/Contents/MacOS/Lidless"
    test -x "$helper"
    plutil -lint "$daemon_plist" >/dev/null
    codesign --verify --deep --strict "$app"
    codesign --verify --strict "$helper"

    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
    if [[ "$bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
        echo "Unexpected bundle identifier: $bundle_id" >&2
        return 1
    fi
    if [[ "$(team_identifier "$app")" != "$EXPECTED_TEAM_ID" ]]; then
        echo "Lidless.app is not signed by Team ID $EXPECTED_TEAM_ID" >&2
        return 1
    fi
    if [[ "$(team_identifier "$helper")" != "$EXPECTED_TEAM_ID" ]]; then
        echo "LidlessHelper is not signed by Team ID $EXPECTED_TEAM_ID" >&2
        return 1
    fi
    if [[ "$(signing_identifier "$helper")" != "$EXPECTED_HELPER_ID" ]]; then
        echo "Unexpected helper signing identifier" >&2
        return 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --destination)
            if [[ $# -lt 2 ]]; then
                echo "--destination requires a path" >&2
                exit 64
            fi
            destination="$2"
            shift 2
            ;;
        --use-existing-build)
            build_first=false
            shift
            ;;
        --no-launch)
            launch_after_install=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [[ "$destination" != /* ]] || [[ "$(basename "$destination")" != "Lidless.app" ]]; then
    echo "Destination must be an absolute path ending in Lidless.app" >&2
    exit 64
fi

destination_parent="$(dirname "$destination")"
if [[ ! -d "$destination_parent" ]]; then
    echo "Destination directory does not exist: $destination_parent" >&2
    exit 1
fi

if [[ "$build_first" == true ]]; then
    "$ROOT/build.sh" app
fi
validate_bundle "$SOURCE_APP"

timestamp="$(date '+%Y%m%d-%H%M%S')"
backup=""
failed_install="$destination.failed-$timestamp"
stage_dir="$(mktemp -d "$destination_parent/.Lidless-install.XXXXXX")"
staged_app="$stage_dir/Lidless.app"
new_bundle_installed=false

rollback() {
    local status="$1"
    trap - EXIT

    if [[ "$status" -ne 0 ]]; then
        if [[ "$new_bundle_installed" == true && -e "$destination" ]]; then
            if [[ -e "$failed_install" ]]; then
                echo "Cannot preserve failed install because path exists: $failed_install" >&2
            else
                mv "$destination" "$failed_install"
                echo "Preserved failed install at $failed_install" >&2
            fi
        fi
        if [[ -n "$backup" && -e "$backup" && ! -e "$destination" ]]; then
            mv "$backup" "$destination"
            echo "Restored previous Lidless from $backup" >&2
        fi
    fi

    if [[ -d "$stage_dir" ]]; then
        rm -rf "$stage_dir"
    fi
    exit "$status"
}
trap 'rollback $?' EXIT

ditto "$SOURCE_APP" "$staged_app"
validate_bundle "$staged_app"

if [[ -e "$destination" ]]; then
    backup="$destination.backup-$timestamp"
    if [[ -e "$backup" ]]; then
        echo "Backup path already exists: $backup" >&2
        exit 1
    fi
    mv "$destination" "$backup"
fi

mv "$staged_app" "$destination"
new_bundle_installed=true
rmdir "$stage_dir"

if [[ "$launch_after_install" == true ]]; then
    /usr/bin/open -n "$destination"
fi

trap - EXIT
echo "Installed verified Lidless at $destination"
if [[ -n "$backup" ]]; then
    echo "Previous version kept at $backup"
fi
