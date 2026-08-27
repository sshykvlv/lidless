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
- [x] Updater validates the outer app, nested service, read-only DMG, exact versions, and fresh post-swap service before installation is accepted.
- [x] Update replacement uses a durable owner-only transaction journal, two-way launch acknowledgement, deterministic startup recovery, and honest rollback-failure reporting.
- [x] Release publication validates assets in a private GitHub draft and makes it public only after downloaded checksums pass.
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

### 2026-08-27 — Live recovery harness prepared

- `./build.sh smoke-app` — universal signed Debug bundle built with private distributed smoke control, exit 0.
- `./build.sh app` plus release-string scan — universal Release bundle built and contains no Debug smoke notification name, exit 0.
- `Scripts/smoke-helper.sh` passed shell syntax validation; its bounded controller fixture compiled for macOS 13 and accepts only fixed smoke operations.
- Live matrix is pending the one visible macOS Background Item approval; baseline remains `SleepDisabled 0`.

### 2026-08-27 — Menu icon and setup language

- Restored the original path-rendered 18×18 sparkle instead of a font-dependent text glyph.
- Removed “helper” terminology from visible menu items, alerts, state text, and notifications; setup now explains Background Items and automatic sleep recovery directly.
- `./build.sh smoke-app` — universal Debug bundle built, signature gate passed, and the verified bundle was reinstalled in `/Applications`, exit 0.
- Normal lid sleep was verified before quit, after quit, and after relaunch with `SleepDisabled 0`.

### 2026-08-27 — Strict update metadata

- RED: focused updater tests failed because `SemanticVersion`, `ReleaseDescriptor`, and `UpdateManifest` did not exist.
- Focused semantic-version and checksum-manifest tests passed after implementing bounded exact parsers.
- `./build.sh test` — 66 tests passed, 0 failures, 0 skipped, exit 0; count verified from the generated xcresult summary.
- Release asset URLs are derived only from a validated three-part version, while manifests accept only lowercase 64-character SHA-256 entries tied to safe exact basenames.

### 2026-08-27 — Bounded download and read-only staging

- RED: mounted-image and update-URL policy tests failed because the policy, session, and URL validation types did not exist.
- Focused mounted-image, hdiutil-plist, detach-idempotency, and URL policy tests passed, including writable/ambiguous/symlink/escape/local-network rejection.
- `./build.sh test` — 75 tests passed, 0 failures, 0 skipped, exit 0.
- `./build.sh app` — bounded downloader, fixed hdiutil adapter, and private stager compiled into both universal slices; all signing/build gates passed.
- `Tests/Fixtures/UpdateStagerSmoke.swift` against a generated UDZO image — `mount=read_only candidate=exact detach=ok cleanup=ok`.
- Downloads enforce HTTPS, no credentials, public destinations, at most five redirects, 30-second timeouts, and actual 32 MiB / 64 KiB byte ceilings; staging rejects non-regular DMGs and any mounted tree over 128 MiB.

### 2026-08-27 — Verified atomic updater

- RED: ordered coordinator tests failed before the update coordinator, identity policy, and compound failure reporting existed; the rollback cleanup test then exposed an unreported secondary cleanup failure.
- Focused coordinator, identity-policy, release-metadata, and app-replacer tests passed, including checksum/identity/disarm/detach/cancellation failures, manual fallback, pre-swap revalidation, atomic rollback, and cleanup after a failed restored-service restart.
- Thread Sanitizer run of the coordinator and real atomic-replacer tests — 12 tests passed with no sanitizer reports.
- `./build.sh test` — 91 tests passed, 0 failures, 0 skipped, exit 0; count verified from the generated xcresult summary.
- `./build.sh app` — app, updater, and background service built universal; signing/build gates passed for both slices.
- `codesign --verify --deep --strict Lidless.app` — exit 0; source scans found no legacy Downloads app deletion or first-asset selection.
- Release metadata is bounded and fixed-origin; the updater verifies SHA-256, signed identity, Team ID, hardened runtime, and Gatekeeper both before and after copying, detaches before restoring normal sleep, swaps only same-directory siblings with `RENAME_SWAP`, and rolls back if service restart or new-process confirmation fails.

### 2026-08-27 — Fail-closed release pipeline

- RED: the release contract failed against the legacy one-step script, which combined build/publication and ignored Gatekeeper failure.
- `bash Tests/BuildContracts/test_release_fail_closed.sh` — build/publish separation, non-ignorable notarization/Gatekeeper gates, strict version rejection, and bounded deletion checks passed.
- `shellcheck release.sh Scripts/validate-release.sh build.sh Tests/BuildContracts/test_release_fail_closed.sh` and `bash -n` — exit 0.
- `./build.sh unsigned-app …` produced an intentionally unsigned universal app; both app/service binaries verified as `arm64 x86_64`, and signature verification correctly failed before explicit release signing.
- Expected-negative `Scripts/validate-release.sh Lidless.app 1.1.0` rejected the local development build for lacking a Developer ID signature.
- `./build.sh test` — 91 tests passed; `./build.sh app`, project-layout, release-contract, and isolated rollback-installer gates all exited 0.
- Release build now signs the background service first, requires hardened runtime/timestamps, waits for an accepted Apple notarization result, staples and validates the app, then atomically emits exact DMG/ZIP/checksum artifacts without publishing. Publication requires exact `origin/main` provenance and revalidates both artifacts before creating a tag or GitHub release.

### 2026-08-27 — Deep-review update recovery

- RED/GREEN coverage added for the three-signal new-app handshake, unreadable sleep state, compound rollback failure, partial `hdiutil` attachment, IPv4-mapped private destinations, partial app copies, manual-DMG cleanup, and durable update transactions.
- `./build.sh test` — 106 tests passed, 0 failures, 0 skipped, exit 0; count verified from the generated xcresult summary.
- `./build.sh test -enableThreadSanitizer YES` — all 106 tests passed with no sanitizer reports, exit 0.
- `./build.sh smoke-app` — universal Debug app and background service built as `arm64 x86_64`, with all local signature/build gates passing.
- `bash Tests/BuildContracts/test_release_fail_closed.sh`, `bash -n`, and ShellCheck — private-draft publication order and cleanup contract passed.
- The staged app validator now checks the nested executable signature, exact Team/bundle/version, hardened runtime, universal architectures, fixed launch-daemon fields, and Mach service. Restart verification uses a fresh XPC connection and requires the expected service version.
- The updater fsyncs a bounded `0600` transaction record before `RENAME_SWAP`, advances it through swapped/committed phases, terminates an unconfirmed new process before rollback, and recovers interrupted states on the next normal launch.
- Partially copied hidden bundles are removed only by the exact inode created for that transaction; unsuccessful manual-install cleanup removes only the exact generated DMG.
- A failed rollback is surfaced as an explicit recovery alert with the preserved old-app path rather than claiming that restoration succeeded.
- Publication now uploads to a private GitHub draft, redownloads and verifies exact checksums, and publishes only as the final external action; an incomplete draft is removed by the release cleanup trap.
- Documentation now states the platform limit accurately: Lidless protects a keep-awake setting that predates its session, but macOS's single global boolean cannot reveal a second tool writing the same value later.
