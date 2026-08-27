#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

test -x release.sh
test -x Scripts/validate-release.sh
grep -Fq "case \"\$command\" in" release.sh
grep -Fq 'build)' release.sh
grep -Fq 'publish)' release.sh
grep -Eq 'notarytool[[:space:]]+submit.*--wait' release.sh
grep -Fq 'gh release create' release.sh
grep -Fq -- '--draft' release.sh
grep -Fq "gh release edit \"\$tag\" --draft=false" release.sh
grep -Fq 'stapler validate' Scripts/validate-release.sh
grep -Fq 'spctl --assess --type execute' Scripts/validate-release.sh

if rg -n 'spctl[^\n]*(\|\|[[:space:]]*true|set[[:space:]]+\+e)' \
  release.sh Scripts/validate-release.sh; then
  echo "Gatekeeper validation can be ignored" >&2
  exit 1
fi

if rg -n 'gh release create' release.sh | grep -F 'build_release'; then
  echo "The build command must not publish" >&2
  exit 1
fi

create_line="$(rg -n "gh release create \\\"\\\$tag\\\"" release.sh | cut -d: -f1)"
download_line="$(rg -n "gh release download \\\"\\\$tag\\\"" release.sh | cut -d: -f1)"
publish_line="$(rg -n "gh release edit \\\"\\\$tag\\\" --draft=false" release.sh | cut -d: -f1)"
test "$create_line" -lt "$download_line"
test "$download_line" -lt "$publish_line"

if rg -n 'rm[[:space:]]+-rf[[:space:]]+"?\$?(HOME|ROOT|repo_root)' \
  release.sh Scripts/validate-release.sh; then
  echo "Release scripts contain an unsafe broad deletion" >&2
  exit 1
fi

if ./release.sh build 1.0.0 invalid-profile >/dev/null 2>&1; then
  echo "Release build accepted a version other than this tree's version" >&2
  exit 1
fi
if ./release.sh publish 1.0.0 >/dev/null 2>&1; then
  echo "Release publication accepted a version other than this tree's version" >&2
  exit 1
fi
