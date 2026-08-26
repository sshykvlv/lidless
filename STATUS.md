# Lidless 1.1.0 status

Tracking issue: [#4 — Make battery cutoff fail-safe and harden update/release path](https://github.com/sshykvlv/lidless/issues/4)

## Acceptance checklist

- [x] XcodeGen project separates `Lidless`, `LidlessHelper`, `LidlessCore`, and `LidlessTests`.
- [x] App and helper build as universal `arm64 x86_64` binaries.
- [x] Local app and nested helper signatures resolve to Team ID `J2Q78NFXZX`.
- [x] Built Info.plist reports version `1.1.0`, `LSUIElement=true`, macOS 13.0 minimum, and no `NSAppSleepDisabled`.
- [x] Installer validates both signatures, keeps one explicit timestamped backup, and does not mutate sudoers.
- [ ] Battery policy uses the exact `<= floor` boundary and responds to power-source notifications.
- [ ] Root helper journals intent before `pmset`, verifies readback, and enforces the 30-second liveness lease.
- [ ] XPC accepts only the signed Lidless client and exposes fixed operations.
- [ ] App coordinator renews every 10 seconds under scoped App Nap activity and renders authoritative helper state.
- [ ] Updater validates a read-only DMG before extraction and performs rollback-capable atomic replacement.
- [ ] Release artifacts pass signing, notarization, stapling, Gatekeeper, checksum, and Homebrew verification.

## Evidence

### 2026-08-26 — Build foundation

- `bash Tests/BuildContracts/test_project_layout.sh` — exit 0.
- `./build.sh test` — 1 XCTest, 0 failures, exit 0.
- `./build.sh app` — exit 0; app and helper both `x86_64 arm64`.
- `bash Tests/BuildContracts/test_install.sh` — exit 0 against an isolated temporary Applications directory.
- `codesign --verify --deep --strict Lidless.app` — exit 0.
