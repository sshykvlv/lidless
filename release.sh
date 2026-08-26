#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
readonly ROOT
readonly EXPECTED_VERSION="1.1.0"
readonly EXPECTED_TEAM_ID="J2Q78NFXZX"
readonly APP_NAME="Lidless.app"
readonly TAG_PREFIX="v"

TEMP_ROOT=""
ACTIVE_MOUNT=""

fail() {
  echo "Release stopped: $*" >&2
  exit 1
}

cleanup() {
  local status="$?"
  trap - EXIT
  if [[ -n "$ACTIVE_MOUNT" ]]; then
    hdiutil detach "$ACTIVE_MOUNT" >/dev/null 2>&1 || true
    ACTIVE_MOUNT=""
  fi
  if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]]; then
    case "$(basename "$TEMP_ROOT")" in
      lidless-release.*|lidless-publish.*) rm -R -- "$TEMP_ROOT" ;;
      *) echo "Refusing to remove unexpected temporary path: $TEMP_ROOT" >&2 ;;
    esac
  fi
  exit "$status"
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage:
  ./release.sh build 1.1.0 NOTARY_PROFILE
  ./release.sh publish 1.1.0

build creates, signs, notarizes, staples, and validates local artifacts only.
publish verifies those artifacts again, then creates the tag and GitHub release.
USAGE
}

require_version() {
  local version="$1"
  [[ "$version" == "$EXPECTED_VERSION" ]] \
    || fail "this tree can release only version $EXPECTED_VERSION"
}

require_clean_tree() {
  [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]] \
    || fail "worktree must be completely clean"
}

find_developer_id() {
  local identity
  identity="$(
    security find-identity -v -p codesigning \
      | sed -nE "/Developer ID Application:.*\(${EXPECTED_TEAM_ID}\)/ { s/^[^\"]*\"([^\"]+)\".*$/\1/; p; q; }"
  )"
  [[ -n "$identity" ]] || fail "Developer ID Application identity for $EXPECTED_TEAM_ID not found"
  printf '%s\n' "$identity"
}

verify_manifest() {
  local directory="$1"
  local manifest="$directory/SHA256SUMS"
  [[ -f "$manifest" && ! -L "$manifest" ]] || fail "SHA256SUMS is missing or unsafe"

  local lines=0
  local dmg=0
  local zip=0
  local hash name extra
  while read -r hash name extra; do
    [[ -z "${extra:-}" ]] || fail "malformed checksum line"
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || fail "malformed SHA-256"
    case "$name" in
      Lidless.dmg) ((dmg += 1)) ;;
      Lidless.zip) ((zip += 1)) ;;
      *) fail "unexpected checksum target: $name" ;;
    esac
    ((lines += 1))
  done < "$manifest"
  [[ "$lines" -eq 2 && "$dmg" -eq 1 && "$zip" -eq 1 ]] \
    || fail "checksum manifest must contain exactly Lidless.dmg and Lidless.zip"
  (cd "$directory" && shasum -a 256 -c SHA256SUMS)
}

require_single_root_app() {
  local root="$1"
  local count
  count="$(find "$root" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')"
  [[ "$count" == "1" ]] || fail "artifact must contain exactly one root entry"
  [[ -d "$root/$APP_NAME" && ! -L "$root/$APP_NAME" ]] \
    || fail "artifact root entry must be a real $APP_NAME directory"
}

validate_artifact_apps() {
  local directory="$1"
  local version="$2"
  local scratch="$3"
  local mount_point="$scratch/mount"
  local zip_root="$scratch/zip"
  mkdir -p "$mount_point" "$zip_root"
  chmod 700 "$scratch" "$mount_point" "$zip_root"

  ACTIVE_MOUNT="$mount_point"
  hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount_point" \
    "$directory/Lidless.dmg" >/dev/null
  require_single_root_app "$mount_point"
  "$ROOT/Scripts/validate-release.sh" "$mount_point/$APP_NAME" "$version"
  hdiutil detach "$mount_point" >/dev/null
  ACTIVE_MOUNT=""

  ditto -x -k "$directory/Lidless.zip" "$zip_root"
  require_single_root_app "$zip_root"
  "$ROOT/Scripts/validate-release.sh" "$zip_root/$APP_NAME" "$version"
}

replace_dist_file() {
  local source="$1"
  local name="$2"
  local destination="$ROOT/dist/$name"
  [[ -f "$source" && ! -L "$source" ]] || fail "unsafe generated artifact: $source"
  case "$name" in
    Lidless.dmg|Lidless.zip|SHA256SUMS|BUILD_PROVENANCE) ;;
    *) fail "unexpected dist artifact name: $name" ;;
  esac
  if [[ -e "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" ]] \
      || fail "refusing to replace unsafe dist path: $destination"
    rm -- "$destination"
  fi
  mv "$source" "$destination"
}

build_release() {
  local version="$1"
  local profile="$2"
  require_version "$version"
  [[ "$profile" =~ ^[A-Za-z0-9._-]+$ ]] || fail "unsafe notary profile name"
  require_clean_tree

  local identity
  identity="$(find_developer_id)"
  xcrun notarytool history --keychain-profile "$profile" >/dev/null

  cd "$ROOT"
  ./build.sh test

  TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lidless-release.XXXXXX")"
  local app="$TEMP_ROOT/$APP_NAME"
  local helper="$app/Contents/Library/HelperTools/LidlessHelper"
  local derived_data="$TEMP_ROOT/DerivedData"
  ./build.sh unsigned-app "$app" "$derived_data"

  codesign --force --options runtime --timestamp --sign "$identity" "$helper"
  codesign --force --options runtime --timestamp \
    --entitlements "$ROOT/Config/Lidless.entitlements" --sign "$identity" "$app"
  codesign --verify --strict --verbose=2 "$helper"
  codesign --verify --deep --strict --verbose=2 "$app"

  local notary_zip="$TEMP_ROOT/notarization.zip"
  local notary_result="$TEMP_ROOT/notary-result.json"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$notary_zip"
  xcrun notarytool submit "$notary_zip" --keychain-profile "$profile" --wait --output-format json > "$notary_result"
  [[ "$(plutil -extract status raw -o - "$notary_result")" == "Accepted" ]] \
    || fail "Apple did not accept the notarization submission"

  xcrun stapler staple "$app"
  "$ROOT/Scripts/validate-release.sh" "$app" "$version"

  local artifact_root="$TEMP_ROOT/artifacts"
  local dmg_root="$TEMP_ROOT/dmg-root"
  mkdir -m 700 "$artifact_root" "$dmg_root"
  ditto "$app" "$dmg_root/$APP_NAME"
  hdiutil create -quiet -volname Lidless -srcfolder "$dmg_root" -format UDZO \
    "$artifact_root/Lidless.dmg"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$artifact_root/Lidless.zip"
  (
    cd "$artifact_root"
    shasum -a 256 Lidless.dmg Lidless.zip > SHA256SUMS
  )
  verify_manifest "$artifact_root"
  validate_artifact_apps "$artifact_root" "$version" "$TEMP_ROOT/artifact-validation"

  mkdir -p "$ROOT/dist"
  printf 'version=%s\ncommit=%s\n' "$version" "$(git -C "$ROOT" rev-parse HEAD)" \
    > "$artifact_root/BUILD_PROVENANCE"
  replace_dist_file "$artifact_root/Lidless.dmg" Lidless.dmg
  replace_dist_file "$artifact_root/Lidless.zip" Lidless.zip
  replace_dist_file "$artifact_root/SHA256SUMS" SHA256SUMS
  replace_dist_file "$artifact_root/BUILD_PROVENANCE" BUILD_PROVENANCE

  echo "Release build complete:"
  echo "  $ROOT/dist/Lidless.dmg"
  echo "  $ROOT/dist/Lidless.zip"
  echo "  $ROOT/dist/SHA256SUMS"
}

require_absent_remote_tag() {
  local tag="$1"
  local status
  if git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
    fail "remote tag already exists: $tag"
  else
    status="$?"
    [[ "$status" -eq 2 ]] || fail "could not verify remote tag absence"
  fi
}

publish_release() {
  local version="$1"
  require_version "$version"
  require_clean_tree

  local tag="${TAG_PREFIX}${version}"
  git -C "$ROOT" fetch origin main --tags
  require_clean_tree
  [[ "$(git -C "$ROOT" rev-parse HEAD)" == "$(git -C "$ROOT" rev-parse origin/main)" ]] \
    || fail "HEAD must equal origin/main"
  if git -C "$ROOT" show-ref --verify --quiet "refs/tags/$tag"; then
    fail "local tag already exists: $tag"
  fi
  require_absent_remote_tag "$tag"
  gh auth status --hostname github.com >/dev/null

  local asset
  for asset in Lidless.dmg Lidless.zip SHA256SUMS BUILD_PROVENANCE; do
    [[ -f "$ROOT/dist/$asset" && ! -L "$ROOT/dist/$asset" ]] \
      || fail "missing or unsafe dist/$asset"
  done
  [[ -f "$ROOT/dist/RELEASE_NOTES.md" && ! -L "$ROOT/dist/RELEASE_NOTES.md" ]] \
    || fail "dist/RELEASE_NOTES.md is missing"
  grep -Fxq "version=$version" "$ROOT/dist/BUILD_PROVENANCE" \
    || fail "artifact version provenance mismatch"
  grep -Fxq "commit=$(git -C "$ROOT" rev-parse HEAD)" "$ROOT/dist/BUILD_PROVENANCE" \
    || fail "artifacts were built from another commit"

  verify_manifest "$ROOT/dist"
  TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lidless-publish.XXXXXX")"
  validate_artifact_apps "$ROOT/dist" "$version" "$TEMP_ROOT/prepublish-validation"

  git -C "$ROOT" tag -a "$tag" -m "Lidless $version"
  git -C "$ROOT" push origin "$tag"
  cd "$ROOT"
  gh release create "$tag" dist/Lidless.dmg dist/Lidless.zip dist/SHA256SUMS \
    --title "Lidless $version" --notes-file dist/RELEASE_NOTES.md

  local downloaded="$TEMP_ROOT/published"
  mkdir -m 700 "$downloaded"
  gh release download "$tag" --dir "$downloaded" \
    --pattern Lidless.dmg --pattern Lidless.zip --pattern SHA256SUMS
  cmp "$ROOT/dist/SHA256SUMS" "$downloaded/SHA256SUMS"
  verify_manifest "$downloaded"
  echo "GitHub publication verified: $tag"
}

command="${1:-}"
case "$command" in
  build)
    [[ $# -eq 3 ]] || { usage >&2; exit 64; }
    build_release "$2" "$3"
    ;;
  publish)
    [[ $# -eq 2 ]] || { usage >&2; exit 64; }
    publish_release "$2"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
