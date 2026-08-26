# Changelog

## 1.1.0 — 2026-08-27

### Added

- Reproducible XcodeGen project with separate app, privileged-helper, shared-core, and XCTest targets.
- Canonical `./build.sh test` and `./build.sh app` workflows for macOS 13+ universal builds.
- Verified installer that preserves the previous app as a timestamped backup and rejects bundles outside Team ID `J2Q78NFXZX`.
- Pure fail-safe battery policy with validated floors, exact `<=` cutoff semantics, and stale/future sample rejection.
- Fixed-command `pmset` adapter with strict output parsing, bounded execution, zero-exit enforcement, and post-mutation readback.
- Root-helper write-ahead journal with binary plist encoding, owner-only permissions, atomic replace, and file/directory durability syncs.
- Serial helper ownership state machine with crash recovery, 30-second monotonic leases, disconnect handling, fail-closed renewals, and retryable fault state.
- Versioned secure-coding XPC contract with per-connection ownership, exact operation allowlist, signed-client authentication, and bounded recovery retry.
- Event-driven IOKit battery sampling with internal-battery selection, a signed helper client, 10-second lease renewal, and scoped App Nap activity.
- Native menu states for helper registration/approval, authoritative active/restoring/fault/external ownership, explicit recovery, bounded diagnostics, and verified Quit/Uninstall flows.
- Exact historical-grant migrator that refuses unknown paths, contents, owners, modes, file types, and sizes.
- Strict semantic-version, fixed release-URL, and bounded exact-checksum parsers for update artifacts.
- Bounded credential-free HTTPS downloads plus private read-only DMG staging that accepts only one real top-level `Lidless.app` and detaches idempotently.
- Signed update validation and rollback-capable same-directory atomic replacement, with verified-DMG manual fallback for unwritable installations.
- One-time Background Items setup with no recurring password prompt, plus explicit removal that first verifies normal lid sleep.
- Plain battery-cutoff choices for Off, 10%, 20%, and 30%; legacy 5%/15% prerelease preferences migrate to the next safer choice.

### Changed

- Replaced the polling-only battery cutoff with a fail-safe background-service architecture tracked in issue #4.
- Replaced the legacy single-file polling UI and privilege fallback with a signed `SMAppService` lifecycle and bounded authenticated XPC.
- Restored the original 18×18 menu-bar sparkle and replaced user-facing “helper” jargon with plain setup and Background Items language.
- Replaced the synchronous legacy updater with bounded async release checks, explicit progress states, checksum/signature/Gatekeeper verification, and compound failure reporting.
- Normal lid sleep now recovers after cutoff, quit, crash, force-kill, lease expiry, service restart, and reboot recovery; external keep-awake ownership remains untouched.

### Removed

- New installs no longer create or modify `/etc/sudoers.d/lidless`.
- Removed the legacy root `main.swift` and `Info.plist`; XcodeGen sources are now canonical.

### Testing

- Added a Debug-only live recovery harness for arm/disarm, exact-floor cutoff, app termination, helper restart, unsigned-client rejection, and protocol-version rejection; Release binaries exclude the control surface.
- Added 100 deterministic unit tests plus build, installer, release, universal-architecture, signature, and Thread Sanitizer gates.
