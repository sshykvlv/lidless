#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

test -f project.yml

contract_dir="$(mktemp -d)"
trap 'rm -rf "$contract_dir"' EXIT

xcodegen generate --spec project.yml --project "$contract_dir"
xcodebuild -project "$contract_dir/Lidless.xcodeproj" -list \
  | grep -q "LidlessTests"
