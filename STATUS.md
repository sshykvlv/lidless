# Lidless 1.1.0 status

Tracking issue: [#4 — Make battery cutoff fail-safe and harden update/release path](https://github.com/sshykvlv/lidless/issues/4)

## Acceptance checklist

- [x] XcodeGen project separates `Lidless`, `LidlessHelper`, `LidlessCore`, and `LidlessTests`.
- [x] App and helper build as universal `arm64 x86_64` binaries.
- [x] Local app and nested helper signatures resolve to Team ID `J2Q78NFXZX`.
- [x] Built Info.plist reports version `1.1.0`, `LSUIElement=true`, macOS 13.0 minimum, and no `NSAppSleepDisabled`.
- [x] Installer validates both signatures, keeps one explicit timestamped backup, and does not mutate sudoers.
- [x] Battery policy uses the exact `<= floor` boundary and fails closed for stale, future, unknown, or incomplete samples.
- [x] Power sampling responds to IOKit power-source notifications.
- [x] `pmset` access uses only fixed executable/arguments, a five-second timeout, strict parsing, and verified readback.
- [x] Root helper journal persists intent atomically with `0600` file / `0700` directory permissions and retains corrupt or failed state.
- [x] Helper state machine enforces ownership, verified restoration, recovery, external-change handling, and the 30-second liveness lease.
- [x] XPC accepts only the signed Lidless client and exposes fixed operations.
- [x] App coordinator renews every 10 seconds under scoped App Nap activity.
- [x] Menu renders authoritative helper state, registration/approval state, and external ownership.
- [ ] Updater validates a read-only DMG before extraction and performs rollback-capable atomic replacement.
- [ ] Release artifacts pass signing, notarization, stapling, Gatekeeper, checksum, and Homebrew verification.

## Evidence

### 2026-08-26 — Build foundation

- `bash Tests/BuildContracts/test_project_layout.sh` — exit 0.
- `./build.sh test` — 1 XCTest, 0 failures, exit 0.
- `./build.sh app` — exit 0; app and helper both `x86_64 arm64`.
- `bash Tests/BuildContracts/test_install.sh` — exit 0 against an isolated temporary Applications directory.
- `codesign --verify --deep --strict Lidless.app` — exit 0.

### 2026-08-26 — Battery safety policy

- `./build.sh test -only-testing:LidlessTests/SafetyPolicyTests` — 8 boundary/validation tests passed, exit 0.
- `./build.sh test` — 9 total tests passed, 0 failures, exit 0.
- Verified cutoff at both 10% and 9%, allowance at 11%, 15-second age boundary, and 5-second future-skew boundary.

### 2026-08-26 — Verified pmset adapter

- `./build.sh test -only-testing:LidlessTests/PMSetParserTests` — 7 parser/command/readback tests passed, exit 0.
- `./build.sh test` — 16 total tests passed, 0 failures, exit 0.
- `./build.sh app` — helper runner typechecked and linked into both universal slices, exit 0.
- `/usr/bin/pmset -g` exposed the expected strict `SleepDisabled 0` line; no mutation command was run during verification.

### 2026-08-26 — Privileged ownership journal

- `./build.sh test -only-testing:LidlessTests/HelperJournalTests` — 5 filesystem/durability tests passed, exit 0.
- `./build.sh test` — 21 total tests passed, 0 failures, exit 0.
- Verified binary-plist round trip, `0600`/`0700` modes, corrupt-file retention, idempotent clear with directory fsync, and preservation of the previous journal when file fsync is injected to fail.

### 2026-08-26 — Fail-safe helper state machine

- `./build.sh test -only-testing:LidlessTests/HelperEngineTests` — 15 ownership/recovery/lease tests passed, exit 0.
- `./build.sh test` — 36 total tests passed, 0 failures, exit 0.
- `./build.sh app` — universal app/helper link passed after the engine integration, exit 0.
- Thread Sanitizer run of all 36 tests — 0 failures and no sanitizer reports.
- Verified journal-before-mutation ordering, exact lease deadline, disconnect restoration, corrupt-journal fail-safe, external ownership loss, stale/unsafe renewals, readback mismatch retention, and fault recovery retry.

### 2026-08-26 — Authenticated XPC boundary

- `./build.sh test -only-testing:LidlessTests/ProtocolTests` — 6 secure-coding, validation, requirement, and exact-selector tests passed, exit 0.
- `./build.sh test` — 42 total tests passed, 0 failures, exit 0.
- `./build.sh app` — authenticated helper daemon linked into both universal slices, exit 0.
- Helper signature resolves to identifier `lv.ykv.lidless.helper` and Team ID `J2Q78NFXZX`; app requirement pins `lv.ykv.lidless` to the same Team ID before connection activation.
- Launch daemon plist passed `plutil`; helper symbol scan found no `system`, `popen`, or `AuthorizationExecuteWithPrivileges` entry points.
- Standalone unsigned probe compiled with no Team ID and is kept outside every shipping target for installed-service rejection testing.

### 2026-08-26 — Event-driven battery safety lease

- `./build.sh test -only-testing:LidlessTests/SafetyCoordinatorTests` — 9 lifecycle, cutoff, failure, and reentrancy tests passed, exit 0.
- `./build.sh test` — 51 total tests passed, 0 failures, exit 0.
- `./build.sh app` — IOKit sampler, signed XPC client, common-mode scheduler, and scoped process activity linked into both universal slices, exit 0.
- Thread Sanitizer run of all 51 tests — 0 failures and no sanitizer reports.
- Verified exact 10-second renewal interval, immediate `<= floor` disarm on notification/floor change, local teardown after every helper failure, and protection against an old arm callback stopping a replacement session.
- Live read-only IOKit snapshot returned `Battery Power`, an `InternalBattery`, and a valid `61/100` capacity tuple on the development Mac.
- Built app contains the fixed privileged Mach service name and still has no `NSAppSleepDisabled` key.

### 2026-08-27 — Visible helper lifecycle and exact legacy cleanup

- `./build.sh test -only-testing:LidlessTests/LegacyGrantMigratorTests` — 7 fixed-path/content/metadata tests passed, exit 0.
- `./build.sh test` — 59 total tests passed, 0 failures, exit 0.
- Thread Sanitizer run of all 59 tests — 0 failures and no sanitizer reports.
- `./build.sh app` — complete menu app and helper built universal; app/helper signing identifiers and Team ID passed build gates.
- Project-layout and rollback installer contracts passed against the completed signed bundle; invalid CLI arguments exit with `EX_USAGE` without starting UI.
- Verified external keep-awake state is observed but never claimed, helper approval has an explicit System Settings action, XPC calls are bounded to five seconds, and custom Quit tears down scoped activity before termination.
- Legacy cleanup inspects only `/etc/sudoers.d/lidless` and `/etc/sudoers.d/keepawake`, rejects symlinks/edited/writable/non-root/oversized files, and leaves every unknown case for manual review.
