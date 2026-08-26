# Lidless 1.1 Fail-safe Battery Cutoff Design

- **Date:** 2026-08-26
- **Status:** Proposed for implementation
- **Issue:** [#4 — Make battery cutoff fail-safe across app and privilege failures](https://github.com/sshykvlv/lidless/issues/4)
- **Target release:** 1.1.0
- **Compatibility:** macOS 13+, Apple Silicon and Intel

## Summary

Lidless currently relies on one menu-bar process to poll the battery and run
privileged `pmset` commands. The safety boundary therefore fails if that process
is throttled, blocked behind an unseen password dialog, terminated, or unable to
confirm that `pmset` actually changed the system setting.

Version 1.1.0 will move ownership of `pmset disablesleep` into a signed,
least-privilege launch daemon registered through `SMAppService`. The app will
monitor power changes, send fresh safety leases to the helper, and make the
battery-floor decision immediately. The helper will independently enforce lease
freshness and the same pure cutoff rule, journal the original system value before
changing it, and restore normal lid-sleep behavior whenever the app disarms,
disconnects, crashes, stops renewing, or the helper restarts.

The release also hardens the self-updater and release pipeline so an update is
never installed before its identity is verified and a release cannot continue
after a failed Gatekeeper, signing, test, or helper check.

## Goals

1. Treat the configured battery floor as a fail-safe boundary: while on battery,
   `percentage <= floor` cannot keep a Lidless-owned session armed.
2. Restore normal lid-sleep behavior after a normal quit, force-quit, app crash,
   App Nap/starvation, lost XPC connection, helper crash/restart, or reboot.
3. Remove recurring administrator password prompts without granting the user or
   app arbitrary root access to `pmset`.
4. Preserve ownership boundaries: never overwrite a pre-existing external
   `SleepDisabled` setting without an explicit user action.
5. Make operational state observable in the menu and unified logs.
6. Preserve the current small native menu-bar experience, macOS 13 minimum, and
   universal Apple Silicon/Intel distribution.
7. Make update installation and release publication fail closed.

## Non-goals

- A visual redesign, Dock app, settings window, or onboarding wizard.
- Thermal monitoring or automatic thermal shutdown.
- Analytics, telemetry, remote control, or any network activity other than the
  existing update check.
- Supporting macOS 12 or older.
- Silently installing or approving privileged components.
- Managing other applications that intentionally set `SleepDisabled`.

## Approaches considered

### 1. Keep all logic in the menu-bar app

Adding `ProcessInfo.beginActivity`, power-source notifications, and stronger
timers would reduce missed checks. It cannot restore the global setting after a
crash, force-quit, or reboot, and a blocking authorization dialog can still make
the cutoff ineffective. This is necessary app-side hardening, but insufficient
as the safety boundary.

### 2. Keep scoped sudoers rules and add a shell watchdog

A user LaunchAgent cannot restore a root-owned setting without retaining a
passwordless privilege path. A root shell watchdog would be harder to authenticate,
version, observe, and test than a typed helper, while still leaving command and
argument parsing as attack surface. This approach is rejected.

### 3. Signed helper with a short safety lease — selected

A launch daemon registered by `SMAppService` can own exactly the privileged
operation Lidless requires. A narrow authenticated XPC protocol, write-ahead
state record, and expiring lease provide recovery even when the app disappears.
This adds a small background component, but it is the only option that closes the
failure modes without a standing sudoers grant.

## Architecture

The source tree will be migrated from a single manually compiled Swift file to
an XcodeGen-managed project. `project.yml` is the source of truth; generated
`.xcodeproj` files are not committed. XcodeGen is a development/build dependency,
not a runtime dependency.

The project has four targets:

- **LidlessApp** — AppKit menu-bar UI, preferences, battery monitoring, update
  coordination, notifications, and helper lifecycle.
- **LidlessHelper** — root launch daemon embedded in the signed app, registered
  with `SMAppService.daemon(plistName:)`, and reachable only through its named
  XPC Mach service.
- **LidlessCore** — dependency-free Swift code shared by the app and helper:
  cutoff decisions, validated data types, protocol versioning, state transitions,
  and update identity rules.
- **LidlessTests** — unit and integration-style tests using fake battery, clock,
  command runner, state store, and XPC adapters. Tests never change real `pmset`
  state.

The helper executable and launchd property list are embedded at fixed bundle
paths and signed with the same Team ID as the outer app. The plist uses a fixed
label and Mach service name under `lv.ykv.lidless`; it accepts no executable path,
command, shell fragment, environment, or arbitrary file path from the client.

## Trust boundary and XPC protocol

For every new XPC connection, the helper obtains the peer audit token and uses
the Security framework to validate the running code. It requires:

- a valid Apple code signature;
- Team ID `J2Q78NFXZX`;
- bundle identifier `lv.ykv.lidless`;
- the expected designated requirement; and
- no invalidated or unsigned nested code.

The connection is rejected before an exported object is installed if any check
fails. Release verification includes a negative test using an unsigned client.

The versioned protocol exposes only these operations:

1. `status()` — return helper version, registration state, ownership state,
   observed `SleepDisabled`, and a structured fault code.
2. `arm(sample)` — begin a new Lidless-owned session using a fresh power sample.
3. `renew(sessionID, sample)` — renew an existing session with a fresh sample.
4. `disarm(sessionID, reason)` — restore the recorded pre-session value.
5. `removeRecognizedLegacyGrant()` — delete only known legacy Lidless/KeepAwake
   sudoers files whose canonical contents match an allowlisted historical rule.

Data-transfer objects use `NSSecureCoding`, have strict type/size validation, and
reject unknown protocol versions. Replies use stable error codes rather than raw
stderr. The helper never exposes a generic process runner or arbitrary filesystem
operation.

## Safety lease and cutoff rule

While armed, the app takes a `ProcessInfo` activity token using
`userInitiatedAllowingIdleSystemSleep`. This prevents App Nap from delaying the
monitor without forcing the display on or replacing normal system idle-sleep
policy.

The app listens to IOKit power-source notifications and also renews the helper
lease every 10 seconds from a timer scheduled in common run-loop modes. Every
renewal takes a new power sample; it does not reuse cached battery data. Events
trigger an additional immediate evaluation. Evaluation also runs before arm,
after helper reconnect, at app launch, and whenever the configured floor changes.

The lease expires 30 seconds after the helper receives the most recent accepted
renewal. The helper uses a monotonic clock for the deadline. A wall-clock
timestamp may be logged but never determines safety.

`LidlessCore` defines one cutoff decision used by both processes:

| Power sample | Decision |
| --- | --- |
| AC power or actively charging | Safe to arm/renew |
| Battery and percentage greater than floor | Safe to arm/renew |
| Battery and percentage equal to or below floor | Disarm immediately |
| Battery with missing/invalid percentage | Disarm (fail closed) |
| Unknown/stale power source | Disarm (fail closed) |

The helper rejects an unsafe `arm` or `renew` even if the app mistakenly requests
it. On an unsafe renewal, rejected renewal, expired lease, or XPC invalidation, it
starts restoration immediately. An IOKit event normally makes cutoff immediate;
the 10-second sampling interval and 30-second helper lease bound the fallback
when the app is delayed or disappears.

Restoring `SleepDisabled=0` re-enables macOS normal lid-sleep policy. Lidless does
not call `pmset sleepnow`: reaching the floor with the lid open must not put an
actively used Mac to sleep, and when the lid is closed macOS applies its normal
clamshell policy after the override is removed.

## Privileged state machine and recovery

The helper has five explicit states:

```text
inactive -> activating -> active -> restoring -> inactive
                   |          |          |
                   +----------+----------+-> faulted
```

Before changing `pmset`, the helper reads and strictly parses the observed
`SleepDisabled` value. If it is already `1` and there is no active Lidless journal,
the helper refuses to arm with `externallyDisabled`; the menu explains that the
system is already configured by another owner. This avoids claiming a battery
safety guarantee that Lidless cannot enforce. The user may explicitly choose to
restore normal lid sleep first, then arm Lidless.

For a valid activation, the helper atomically writes a root-owned journal at
`/Library/Application Support/Lidless/state.plist` with mode `0600`. The record
contains only schema version, session UUID, original value, transition state,
helper version, and timestamps. It is written and fsynced before invoking
`/usr/bin/pmset -a disablesleep 1`.

Every `pmset` invocation:

1. uses `/usr/bin/pmset` directly with fixed arguments and no shell;
2. captures bounded stdout/stderr and the termination status;
3. treats nonzero status or timeout as failure; and
4. re-reads `pmset -g` and requires the expected observed value.

Disarm restores the journaled original value and verifies it before deleting the
journal. If restoration fails, the journal remains, the helper enters `faulted`,
and launchd restarts or the running helper retries with bounded backoff while
reporting the fault. A new arm is denied until recovery succeeds.

The launch daemon runs at load to process an unfinished journal before accepting
new client work. It remains alive while a session is active, is restarted by
launchd after an abnormal exit, and may exit when inactive. Therefore a helper
crash, Mac reboot, app crash, force-quit, or normal quit converges back to the
journaled original value.

If another actor changes `SleepDisabled` away from the helper's expected value
during an active session, Lidless does not fight the external change. It ends its
ownership session, preserves the observed external value, clears the journal only
after recording the ownership loss, and reports `externallyChanged` to the app.

## Helper installation and legacy migration

The first attempt to arm checks `SMAppService.status`:

- **not registered:** the app explains why the helper is required and asks the
  user to continue; only then does it call `register()`;
- **requires approval:** the menu shows a persistent setup item and offers to open
  the macOS Login Items settings page;
- **enabled:** the app connects, validates the helper protocol/version, and runs
  a non-mutating health check before offering arm;
- **not found/invalid/mismatched:** the app remains off and offers a repair path.

Approval is always visible and controlled by macOS. Lidless never simulates clicks,
collects a password, or falls back to `osascript` authorization.

After the new helper has successfully completed a controlled arm/disarm round
trip, it may remove `/etc/sudoers.d/lidless` or
`/etc/sudoers.d/keepawake` only when the file is a regular root-owned file and its
normalized contents exactly match a known Lidless rule. Unknown or edited files
are left untouched and reported with manual cleanup instructions. Migration never
runs before helper recovery is proven.

The app provides an **Uninstall helper…** menu action that first disarms, verifies
restoration, unregisters the service, and removes recognized legacy state. The
Homebrew cask uninstall/zap flow invokes the same bounded cleanup path. Manual
drag-to-Trash instructions tell the user to run this action first; even without
it, a disconnected active helper restores the system value when its lease expires.

## Menu and user-visible behavior

The star continues to show the actual system condition, but the menu distinguishes
system state from Lidless ownership:

- **Off — normal lid sleep**: observed `SleepDisabled=0`, no Lidless session.
- **On — Lidless safety active**: helper owns a verified active session.
- **External keep-awake setting detected**: observed value is `1`, but Lidless
  does not own it; the battery floor is explicitly shown as unavailable.
- **Helper approval required**: setup is incomplete and arm is disabled.
- **Restoring/Fault**: the latest structured reason and recovery action are shown.

At cutoff, the app disarms the UI immediately, releases its activity token, posts
a local notification, and records the reason and sampled percentage. If the lid
is closed, the notification will be visible after the next wake. A helper-driven
cutoff discovered after reconnect is presented the same way.

Normal Quit requests verified disarm before terminating. If the reply is lost,
the app reports that the helper's 30-second lease recovery is in progress and
then exits; the helper remains the final safety owner.

## Logging and diagnostics

Both processes use unified logging with subsystem `lv.ykv.lidless` and separate
categories for battery, helper, state, update, and release diagnostics. Events
include transition, reason, observed value, percentage/floor, helper version,
result code, and elapsed time. They do not include usernames, paths outside
Lidless-owned locations, process output that may contain private data, or any
network identifiers.

The menu exposes **Copy diagnostics**. It returns a bounded, redacted snapshot of
versions, helper status, current power sample, configured floor, observed system
value, and the latest Lidless error codes. It never copies the root journal or
arbitrary system logs.

## Self-update hardening

The updater remains unprivileged and cannot call the `pmset` helper to install
files. It follows this order:

1. Download the archive and checksum into a unique private temporary directory
   with strict response-size and timeout bounds.
2. Verify the archive SHA-256 against the exact versioned manifest entry.
3. Extract only inside that temporary directory; reject symlinks, path traversal,
   unexpected top-level candidates, or a candidate outside the resolved staging
   root.
4. Validate the staged app before touching the installed copy: bundle ID
   `lv.ykv.lidless`, exact expected version, Team ID `J2Q78NFXZX`, designated
   requirement, nested-code signature, hardened runtime, and Gatekeeper
   acceptance.
5. Ask the helper to disarm and require verified restoration.
6. Atomically replace the installed app only when its containing directory is
   writable. If it is not writable, leave the staged/release download available
   for an explicit manual install; do not request generic root file-copy access.
7. Launch the new app, which reconciles helper protocol compatibility before arm.

The updater never pre-deletes `~/Downloads/Lidless.app`, never executes or opens
an unverified candidate, and never treats missing validation output as success.
On failure it leaves the running installation unchanged and presents a stable
error plus the GitHub release page.

## Build and release pipeline

`build.sh`, `install.sh`, and `release.sh` become thin fail-fast entry points over
the XcodeGen project. Local development supports an Apple Development identity;
shipping requires the configured Developer ID Application identity. Release
1.1.0 is blocked unless all of the following pass:

1. XcodeGen project generation and a clean Release build.
2. Unit tests and helper integration tests.
3. Universal `arm64` + `x86_64` slices for the app and helper.
4. Hardened-runtime signatures for every nested executable and the outer bundle.
5. Exact Team ID, bundle IDs, entitlements, and designated requirements.
6. A local clean-state smoke test and forced-app-termination recovery test.
7. Archive checksum generation and independent verification.
8. Notarization, stapling, `codesign --verify --deep --strict`, and successful
   `spctl --assess`; no release check is followed by `|| true`.
9. Installation of the final archive on a clean temporary path and a launch test.
10. GitHub release publication, then Homebrew cask version/SHA update and landing
    page/version verification.

The GitHub release is created only after the notarized artifact passes every gate.
Homebrew is updated only from the immutable published archive checksum. Production
publication remains a main-agent/manual-owner action, never a delegated action.

## Test strategy

### Unit tests

- Battery values `11 -> 10`, exact equality, below-floor, and floor changes while
  active.
- AC, charging, battery, missing percentage, stale sample, and unknown source.
- Arm refusal at or below the floor and when an external `SleepDisabled=1` exists.
- Journal-before-mutation ordering and preservation of the original value.
- Idempotent arm/disarm, wrong session IDs, duplicate replies, and protocol mismatch.
- App disconnect, 30-second lease expiry, helper restart, and boot recovery.
- `pmset` nonzero exit, timeout, malformed output, verify mismatch, retry, and
  journal retention after failed restore.
- External changes during an owned session.
- Strict legacy sudoers recognition; modified files are never removed.
- Update checksum, version, bundle/team identity, symlink/path traversal, staging,
  and replacement failure cases.

### Automated integration tests

A non-root fake command runner and temporary state directory exercise the real
helper state machine over XPC without changing system power settings. A test
client with the wrong identity confirms rejection where the CI signing environment
supports it; the final signed bundle repeats this as a release smoke check.

### Live macOS smoke tests

On the current Mac, with the original value recorded first:

1. Register/approve the helper and confirm healthy protocol negotiation.
2. Arm and verify `pmset -g` reports `SleepDisabled 1`.
3. Disarm and verify restoration to the recorded original value.
4. Arm, terminate the UI process, and verify restoration within 30 seconds.
5. Arm and inject a debug-only simulated transition from 11% to 10%; verify
   immediate disarm without draining the real battery.
6. Verify normal Quit and helper restart recovery.
7. Install the final notarized archive and verify Gatekeeper acceptance, launch,
   helper registration, and universal slices.

The debug battery provider is compiled only for tests/debug builds and cannot be
selected in a Release build.

## Documentation and rollout

Before release, update README, CHANGELOG, STATUS, Homebrew cleanup, and release
notes. The README must no longer claim "No daemon" or describe sudoers as the
normal setup. It will explain the small signed helper, visible macOS approval,
lease recovery, external-setting state, and uninstall procedure.

Rollout is a single 1.1.0 release after clean-machine-style verification. There is
no automatic migration that turns keep-awake on. Existing preferences, including
the battery floor, remain; the first arm performs helper setup and migration.

## Acceptance criteria

Implementation is complete only when every checkbox in issue #4 is demonstrably
met, all automated and live tests above pass, the final artifact is notarized and
Gatekeeper-accepted, the release notes match actual behavior, and the GitHub and
Homebrew artifacts resolve to the same SHA-256-verified app.
