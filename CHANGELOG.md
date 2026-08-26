# Changelog

## Unreleased — 1.1.0

### Added

- Reproducible XcodeGen project with separate app, privileged-helper, shared-core, and XCTest targets.
- Canonical `./build.sh test` and `./build.sh app` workflows for macOS 13+ universal builds.
- Verified installer that preserves the previous app as a timestamped backup and rejects bundles outside Team ID `J2Q78NFXZX`.
- Pure fail-safe battery policy with validated floors, exact `<=` cutoff semantics, and stale/future sample rejection.
- Fixed-command `pmset` adapter with strict output parsing, bounded execution, zero-exit enforcement, and post-mutation readback.

### Changed

- Began replacing the polling-only battery cutoff with a fail-safe helper architecture tracked in issue #4.

### Removed

- New installs no longer create or modify `/etc/sudoers.d/lidless`.
