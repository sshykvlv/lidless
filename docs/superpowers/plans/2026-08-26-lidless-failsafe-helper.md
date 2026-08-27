# Lidless Fail-safe Helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace direct privileged `pmset` calls with an authenticated, journaled, lease-based helper so Lidless reliably restores normal lid sleep at the configured battery floor and after process failures.

**Architecture:** A static `LidlessCore` target owns pure safety policy, protocol DTOs, pmset parsing, journaling, and an injected helper state machine. A root `LidlessHelper` launch daemon exposes only the versioned XPC operations, while the AppKit app samples IOKit power state and renews a 30-second helper lease every 10 seconds. XcodeGen becomes the build source of truth so app, helper, and tests are built and signed together.

**Tech Stack:** Swift 6, AppKit, Foundation/XPC, ServiceManagement `SMAppService`, IOKit power sources, Security code-signing requirements, OSLog, XcodeGen, XCTest, launchd.

**Spec:** `docs/superpowers/specs/2026-08-26-lidless-failsafe-helper-design.md`

## Global Constraints

- Target release is `1.1.0`; deployment target remains macOS 13.0.
- Build both `arm64` and `x86_64` slices for the app and helper.
- The shipping bundle and helper use Team ID `J2Q78NFXZX`.
- The app bundle identifier remains `lv.ykv.lidless`; helper identifier and Mach service are `lv.ykv.lidless.helper`.
- The helper accepts no shell command, executable path, arbitrary arguments, or arbitrary filesystem path over XPC.
- All `pmset` mutations use `/usr/bin/pmset` with fixed arguments and require read-back verification.
- Battery cutoff uses `percentage <= floor`; a disabled floor does not veto the lease.
- Unknown/stale battery data fails closed whenever a floor is enabled.
- The helper lease renews every 10 seconds and expires after 30 seconds using a monotonic clock.
- Preserve user preferences, including `batteryFloor`; keep the existing default of 20% for a new profile.
- Do not include the blanket `NSAppSleepDisabled` plist key; hold a scoped `ProcessInfo` activity only while armed.
- Do not install sudoers rules or fall back to `sudo`, `osascript`, or generic authorization.
- Use structured unified logging and never log secrets or unrestricted subprocess output.
- Work only in `fix/failsafe-cutoff`; stage explicit files and preserve unrelated user changes.
- Follow red-green-refactor for every behavior task and update `STATUS.md` plus `CHANGELOG.md` before each completed commit.
- Keep `implementation-notes.md` untracked; record material plan deviations there.

## File Structure

```text
project.yml                                      XcodeGen source of truth
.gitignore                                       Generated build/work files
Config/Lidless-Info.plist                        App metadata, version 1.1.0
Config/Lidless.entitlements                      App entitlements
Config/lv.ykv.lidless.helper.plist               LaunchDaemon/Mach service definition
Sources/LidlessCore/PowerSample.swift            Validated power sample and floor types
Sources/LidlessCore/SafetyPolicy.swift           Pure cutoff decision
Sources/LidlessCore/PMSet.swift                   Strict parser and injected controller contract
Sources/LidlessCore/HelperJournal.swift           Journal model/store contract and POSIX store
Sources/LidlessCore/HelperEngine.swift            Privileged ownership state machine
Sources/LidlessCore/HelperProtocol.swift          NSSecureCoding XPC DTOs and protocol
Sources/LidlessCore/CodeSigningRequirements.swift Fixed client/helper requirements
Sources/LidlessCore/SafetyCoordinator.swift        Testable app lease lifecycle
Sources/LidlessCore/LegacyGrantMigrator.swift      Injected allowlist-only cleanup
Sources/LidlessHelper/main.swift                  Recovery-first daemon bootstrap
Sources/LidlessHelper/PMSetCommandRunner.swift    Bounded fixed-command adapter
Sources/LidlessHelper/HelperService.swift         Listener and per-connection XPC session
Sources/LidlessApp/main.swift                     AppKit bootstrap
Sources/LidlessApp/AppDelegate.swift              Menu construction and user actions
Sources/LidlessApp/BatteryMonitor.swift           IOKit event source and snapshots
Sources/LidlessApp/HelperClient.swift              SMAppService and XPC client adapter
Sources/LidlessApp/SafetyAdapters.swift            Process activity/timer/notification adapters
Sources/LidlessApp/MenuState.swift                System-vs-Lidless display model
Tests/LidlessTests/SafetyPolicyTests.swift         Battery boundary matrix
Tests/LidlessTests/PMSetParserTests.swift          Strict system-state parsing
Tests/LidlessTests/HelperJournalTests.swift        Persistence and permissions
Tests/LidlessTests/HelperEngineTests.swift         Arm/disarm/failure/recovery behavior
Tests/LidlessTests/ProtocolTests.swift             Secure DTO and requirement contracts
Tests/LidlessTests/SafetyCoordinatorTests.swift    App lifecycle with fakes
Tests/LidlessTests/LegacyGrantMigratorTests.swift  Allowlist-only deletion
Tests/Fixtures/UnsignedHelperProbe.swift            Negative XPC identity probe
Tests/BuildContracts/test_project_layout.sh        Product/layout/universal checks
Scripts/smoke-helper.sh                            Reversible live safety smoke test
build.sh                                           Fail-fast local build wrapper
install.sh                                         Safe install without sudoers
CHANGELOG.md                                       1.1.0 release notes in progress
STATUS.md                                          Acceptance and evidence ledger
```

The legacy root `main.swift` and root `Info.plist` are removed only after the new
app builds and tests pass. Assets stay at their current paths.

---

### Task 1: Establish the XcodeGen build and proof ledger

**Files:**
- Create: `project.yml`
- Create: `.gitignore`
- Create: `Config/Lidless-Info.plist`
- Create: `Config/Lidless.entitlements`
- Create: `Config/lv.ykv.lidless.helper.plist`
- Create: `Sources/LidlessApp/main.swift`
- Create: `Sources/LidlessHelper/main.swift`
- Create: `Sources/LidlessCore/BuildMarker.swift`
- Create: `Tests/LidlessTests/BuildMarkerTests.swift`
- Create: `Tests/BuildContracts/test_project_layout.sh`
- Create: `CHANGELOG.md`
- Create: `STATUS.md`
- Modify: `build.sh`
- Modify: `install.sh`

**Interfaces:**
- Produces: schemes `Lidless` and `LidlessTests`; products `Lidless.app`, `LidlessHelper`, and static module `LidlessCore`.
- Produces: `./build.sh test` and `./build.sh app` as canonical local commands.

- [ ] **Step 1: Write the failing build-contract test**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test -f project.yml
contract_dir="$(mktemp -d)"
trap 'rm -rf "$contract_dir"' EXIT
xcodegen generate --spec project.yml --project "$contract_dir"
xcodebuild -project "$contract_dir/Lidless.xcodeproj" -list \
  | grep -q 'LidlessTests'
```

- [ ] **Step 2: Run the contract to verify it fails**

Run: `bash Tests/BuildContracts/test_project_layout.sh`

Expected: FAIL because `project.yml` does not exist.

- [ ] **Step 3: Add the minimal project and test target**

Use these exact target identities and settings in `project.yml`:

```yaml
name: Lidless
options:
  deploymentTarget:
    macOS: "13.0"
settings:
  base:
    SWIFT_VERSION: "6.0"
    DEVELOPMENT_TEAM: J2Q78NFXZX
    CODE_SIGN_STYLE: Automatic
    MACOSX_DEPLOYMENT_TARGET: "13.0"
targets:
  LidlessCore:
    type: library.static
    platform: macOS
    sources: [Sources/LidlessCore]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: lv.ykv.lidless.core
  LidlessHelper:
    type: tool
    platform: macOS
    sources: [Sources/LidlessHelper]
    dependencies:
      - target: LidlessCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: lv.ykv.lidless.helper
        PRODUCT_NAME: LidlessHelper
  Lidless:
    type: application
    platform: macOS
    sources:
      - Sources/LidlessApp
      - path: icon/AppIcon.icns
        buildPhase: resources
    info:
      path: Config/Lidless-Info.plist
    entitlements:
      path: Config/Lidless.entitlements
    dependencies:
      - target: LidlessCore
      - target: LidlessHelper
        embed: false
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: lv.ykv.lidless
        PRODUCT_NAME: Lidless
        MARKETING_VERSION: 1.1.0
        CURRENT_PROJECT_VERSION: 1.1.0
    postBuildScripts:
      - name: Embed signed helper and launchd plist
        script: |
          set -euo pipefail
          helper_dir="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Library/HelperTools"
          daemon_dir="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Library/LaunchDaemons"
          mkdir -p "$helper_dir" "$daemon_dir"
          ditto "$BUILT_PRODUCTS_DIR/LidlessHelper" "$helper_dir/LidlessHelper"
          ditto "$SRCROOT/Config/lv.ykv.lidless.helper.plist" "$daemon_dir/lv.ykv.lidless.helper.plist"
  LidlessTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Tests/LidlessTests]
    dependencies:
      - target: LidlessCore
schemes:
  Lidless:
    build:
      targets:
        Lidless: all
        LidlessTests: [test]
    test:
      targets: [LidlessTests]
```

The app plist contains `LSUIElement=true`, version `1.1.0`, minimum system 13.0,
and no `NSAppSleepDisabled`. The launchd plist contains:

```xml
<key>Label</key><string>lv.ykv.lidless.helper</string>
<key>BundleProgram</key><string>Contents/Library/HelperTools/LidlessHelper</string>
<key>MachServices</key>
<dict><key>lv.ykv.lidless.helper</key><true/></dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key>
<dict><key>SuccessfulExit</key><false/></dict>
```

Make `BuildMarker.supportedVersion == "1.1.0"` and assert it in XCTest. Change
`build.sh` to generate into `.build/Lidless.xcodeproj`, use derived data under
`.build/DerivedData`, and implement only `test|app|clean`. Test builds disable
signing; app builds use local Apple Development automatic signing, never release
signing/notarization. `install.sh` calls `./build.sh app`, requires a valid nested
signature and Team ID `J2Q78NFXZX`, moves an existing
`/Applications/Lidless.app` to one explicit timestamped sibling backup, copies
the new bundle with `ditto`, opens it, and restores the backup if launch fails.
It must contain no sudoers mutation and must never recursively delete an
unresolved path.

- [ ] **Step 4: Run generation, tests, and contract**

Run:

```bash
bash Tests/BuildContracts/test_project_layout.sh
./build.sh test
./build.sh app
```

Expected: all commands exit 0; `Lidless.app` contains the helper executable and
launchd plist at the exact paths above.

- [ ] **Step 5: Initialize proof files and commit**

Add an `Unreleased / 1.1.0` section to `CHANGELOG.md` and an issue #4 checklist
to `STATUS.md`, recording the three commands and their exit status. Add
`.build/`, `*.xcodeproj`, and `implementation-notes.md` to `.gitignore`.

```bash
git add project.yml .gitignore Config Sources Tests build.sh install.sh CHANGELOG.md STATUS.md
git commit -m "build: establish Lidless 1.1 project and tests (#4)"
git push
```

### Task 2: Implement the pure battery safety policy

**Files:**
- Create: `Sources/LidlessCore/PowerSample.swift`
- Create: `Sources/LidlessCore/SafetyPolicy.swift`
- Create: `Tests/LidlessTests/SafetyPolicyTests.swift`
- Modify: `STATUS.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces: `PowerSource`, `PowerSample`, `BatteryFloor`, `SafetyDecision`, and `SafetyPolicy.evaluate(sample:floor:now:)`.
- Consumes: none beyond Foundation.

- [ ] **Step 1: Write the complete failing boundary matrix**

```swift
import XCTest
@testable import LidlessCore

final class SafetyPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBatteryAboveFloorAllowsLease() {
        XCTAssertEqual(decide(.battery, 11, floor: 10), .allow)
    }

    func testBatteryAtOrBelowFloorCutsOff() {
        XCTAssertEqual(decide(.battery, 10, floor: 10), .cutoff(.atBatteryFloor))
        XCTAssertEqual(decide(.battery, 9, floor: 10), .cutoff(.atBatteryFloor))
    }

    func testACAndChargingAllowLease() {
        XCTAssertEqual(decide(.ac, nil, floor: 10), .allow)
        XCTAssertEqual(decide(.charging, 5, floor: 10), .allow)
    }

    func testUnknownOrMissingBatteryFailsClosedWithFloor() {
        XCTAssertEqual(decide(.unknown, nil, floor: 10), .cutoff(.unknownPower))
        XCTAssertEqual(decide(.battery, nil, floor: 10), .cutoff(.missingPercentage))
    }

    func testDisabledFloorAllowsAnyFreshSample() {
        XCTAssertEqual(decide(.unknown, nil, floor: nil), .allow)
        XCTAssertEqual(decide(.battery, 0, floor: nil), .allow)
    }

    func testStaleOrFutureSampleFailsClosed() {
        let old = PowerSample(source: .battery, percentage: 90, sampledAt: now.addingTimeInterval(-16))
        XCTAssertEqual(SafetyPolicy.evaluate(sample: old, floor: BatteryFloor(10)!, now: now), .cutoff(.staleSample))
        let future = PowerSample(source: .ac, percentage: 90, sampledAt: now.addingTimeInterval(6))
        XCTAssertEqual(SafetyPolicy.evaluate(sample: future, floor: BatteryFloor(10)!, now: now), .cutoff(.futureSample))
    }
}
```

The local `decide` helper creates a sample at `now`; do not weaken production
visibility to satisfy tests.

- [ ] **Step 2: Run the focused test and verify red**

Run: `./build.sh test -only-testing:LidlessTests/SafetyPolicyTests`

Expected: FAIL because the safety types do not exist.

- [ ] **Step 3: Implement validated values and one exhaustive decision**

```swift
public enum PowerSource: Int, Sendable { case ac, charging, battery, unknown }

public struct BatteryFloor: Equatable, Sendable {
    public let percentage: Int?
    public init?(_ percentage: Int?) {
        guard let percentage else { self.percentage = nil; return }
        guard (1...100).contains(percentage) else { return nil }
        self.percentage = percentage
    }
}

public enum SafetyDecision: Equatable, Sendable {
    case allow
    case cutoff(CutoffReason)
}

public enum SafetyPolicy {
    public static func evaluate(sample: PowerSample, floor: BatteryFloor, now: Date) -> SafetyDecision
}
```

Use a 15-second maximum age and 5-second future skew. Return `.allow` first when
`floor.percentage == nil`; otherwise validate freshness, then source and percent.

- [ ] **Step 4: Run focused and full tests**

Run:

```bash
./build.sh test -only-testing:LidlessTests/SafetyPolicyTests
./build.sh test
```

Expected: PASS, 0 failures.

- [ ] **Step 5: Update proof ledger and commit**

```bash
git add Sources/LidlessCore/PowerSample.swift Sources/LidlessCore/SafetyPolicy.swift Tests/LidlessTests/SafetyPolicyTests.swift STATUS.md CHANGELOG.md
git commit -m "feat: define fail-safe battery policy (#4)"
git push
```

### Task 3: Parse and control `pmset` without a shell

**Files:**
- Create: `Sources/LidlessCore/PMSet.swift`
- Create: `Sources/LidlessHelper/PMSetCommandRunner.swift`
- Create: `Tests/LidlessTests/PMSetParserTests.swift`
- Modify: `project.yml`
- Modify: `STATUS.md`

**Interfaces:**
- Produces: `PMSetControlling.readSleepDisabled()`, `PMSetControlling.setSleepDisabled(_:)`, `PMSetSnapshot.parse(_:)`, and `FixedPMSetController`.
- Consumes: fixed executable `/usr/bin/pmset`; no shell.

- [ ] **Step 1: Write strict parser and verification tests**

```swift
func testParsesExactSleepDisabledValue() throws {
    XCTAssertFalse(try PMSetSnapshot.parse("System-wide power settings:\n SleepDisabled 0\n").sleepDisabled)
    XCTAssertTrue(try PMSetSnapshot.parse(" SleepDisabled\t1\n").sleepDisabled)
}

func testRejectsMissingMalformedOrConflictingValues() {
    XCTAssertThrowsError(try PMSetSnapshot.parse("sleep 1"))
    XCTAssertThrowsError(try PMSetSnapshot.parse("SleepDisabled yes"))
    XCTAssertThrowsError(try PMSetSnapshot.parse("SleepDisabled 0\nSleepDisabled 1"))
}

func testSetRequiresZeroExitAndReadBackMatch() throws {
    let runner = FakeCommandRunner(results: [
        .success(status: 0, stdout: "", stderr: ""),
        .success(status: 0, stdout: "SleepDisabled 0", stderr: "")
    ])
    let controller = FixedPMSetController(runner: runner)
    XCTAssertThrowsError(try controller.setSleepDisabled(true))
    XCTAssertEqual(runner.calls, [
        Command("/usr/bin/pmset", ["-a", "disablesleep", "1"]),
        Command("/usr/bin/pmset", ["-g"])
    ])
}
```

- [ ] **Step 2: Run and verify red**

Run: `./build.sh test -only-testing:LidlessTests/PMSetParserTests`

Expected: FAIL because parser/controller contracts do not exist.

- [ ] **Step 3: Implement the injected fixed-command adapter**

```swift
public protocol PMSetControlling: AnyObject {
    func readSleepDisabled() throws -> Bool
    func setSleepDisabled(_ enabled: Bool) throws
}

public protocol CommandRunning: AnyObject {
    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult
}

public final class FixedPMSetController: PMSetControlling {
    public func setSleepDisabled(_ enabled: Bool) throws {
        let value = enabled ? "1" : "0"
        let result = try runner.run(executable: "/usr/bin/pmset", arguments: ["-a", "disablesleep", value], timeout: 5)
        guard result.status == 0 else { throw PMSetError.commandFailed }
        guard try readSleepDisabled() == enabled else { throw PMSetError.verificationMismatch }
    }
}
```

Implement `ProcessCommandRunner` in the helper with concurrent bounded reads for
stdout/stderr, a 5-second timeout, termination on timeout, and 64 KiB maximum per
stream. Tests use only `FakeCommandRunner`.

- [ ] **Step 4: Run focused/full tests and typecheck helper**

```bash
./build.sh test -only-testing:LidlessTests/PMSetParserTests
./build.sh test
./build.sh app
```

Expected: PASS and successful helper link.

- [ ] **Step 5: Record evidence and commit**

```bash
git add Sources/LidlessCore/PMSet.swift Sources/LidlessHelper/PMSetCommandRunner.swift Tests/LidlessTests/PMSetParserTests.swift project.yml STATUS.md
git commit -m "feat: add verified fixed pmset adapter (#4)"
git push
```

### Task 4: Add the root-owned write-ahead journal

**Files:**
- Create: `Sources/LidlessCore/HelperJournal.swift`
- Create: `Tests/LidlessTests/HelperJournalTests.swift`
- Modify: `STATUS.md`

**Interfaces:**
- Produces: `HelperJournal`, `JournalPhase`, `JournalStoring`, and `AtomicJournalStore`.
- Consumes: injected journal URL; production uses `/Library/Application Support/Lidless/state.plist`.

- [ ] **Step 1: Write persistence, permission, and corruption tests**

```swift
func testRoundTripUsesOwnerOnlyPermissions() throws {
    let store = try makeStore()
    let journal = HelperJournal(sessionID: UUID(), connectionID: UUID(), originalSleepDisabled: false, phase: .activating, armedAt: fixedDate)
    try store.save(journal)
    XCTAssertEqual(try store.load(), journal)
    let mode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber)
    XCTAssertEqual(mode.intValue & 0o777, 0o600)
}

func testCorruptJournalIsReportedAndNeverClearedByLoad() throws {
    let store = try makeStore(rawData: Data("not a plist".utf8))
    XCTAssertThrowsError(try store.load())
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
}

func testClearIsIdempotentAndFsyncsContainingDirectory() throws {
    let syscalls = RecordingJournalSyscalls()
    let store = AtomicJournalStore(url: tempURL, syscalls: syscalls)
    try store.save(journal)
    try store.clear()
    try store.clear()
    XCTAssertEqual(syscalls.fsyncedDirectoryURLs.last, tempURL.deletingLastPathComponent())
}
```

- [ ] **Step 2: Run and verify red**

Run: `./build.sh test -only-testing:LidlessTests/HelperJournalTests`

Expected: FAIL because journal contracts do not exist.

- [ ] **Step 3: Implement atomic write-ahead persistence**

```swift
public struct HelperJournal: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public let connectionID: UUID
    public let originalSleepDisabled: Bool
    public var phase: JournalPhase
    public let armedAt: Date
}

public protocol JournalStoring: AnyObject {
    func load() throws -> HelperJournal?
    func save(_ journal: HelperJournal) throws
    func clear() throws
}
```

`AtomicJournalStore.save` creates the parent as root-owned `0700`, encodes a
binary property list, opens a same-directory unique temp file with `O_EXCL` and
mode `0600`, writes all bytes, `fsync`s the file, renames over the destination,
and `fsync`s the directory. On any error it closes/unlinks only its temp file and
does not modify the old journal.

- [ ] **Step 4: Run focused/full tests**

```bash
./build.sh test -only-testing:LidlessTests/HelperJournalTests
./build.sh test
```

Expected: PASS, including the real temporary-filesystem permission assertion.

- [ ] **Step 5: Record evidence and commit**

```bash
git add Sources/LidlessCore/HelperJournal.swift Tests/LidlessTests/HelperJournalTests.swift STATUS.md
git commit -m "feat: journal privileged sleep ownership (#4)"
git push
```

### Task 5: Implement the fail-safe helper state machine

**Files:**
- Create: `Sources/LidlessCore/HelperEngine.swift`
- Create: `Tests/LidlessTests/HelperEngineTests.swift`
- Modify: `STATUS.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces: `HelperEngine.status`, `arm`, `renew`, `disarm`, `connectionInvalidated`, `leaseExpired`, and `recoverAtLaunch`.
- Consumes: `PMSetControlling`, `JournalStoring`, `SafetyPolicy`, injected wall and monotonic clocks.

- [ ] **Step 1: Write arm/disarm ordering and ownership tests**

```swift
func testArmJournalsBeforeMutationAndReturnsOwnedSession() throws {
    pmset.observed = false
    let response = try engine.arm(connectionID: connection, sample: safeBattery, floor: BatteryFloor(10)!)
    XCTAssertEqual(events, [.read(false), .journal(.activating), .set(true), .read(true), .journal(.active)])
    XCTAssertEqual(response.state, .active)
}

func testRefusesExternalSleepDisabledWithoutMutation() {
    pmset.observed = true
    XCTAssertThrowsError(try engine.arm(connectionID: connection, sample: safeBattery, floor: BatteryFloor(10)!)) {
        XCTAssertEqual($0 as? HelperError, .externallyDisabled)
    }
    XCTAssertFalse(events.contains { if case .set = $0 { true } else { false } })
}

func testUnsafeArmNeverWritesJournalOrPmset() {
    XCTAssertThrowsError(try engine.arm(connectionID: connection, sample: atFloor, floor: BatteryFloor(10)!))
    XCTAssertEqual(events, [])
}

func testDisarmRestoresAndClearsOnlyAfterVerification() throws {
    let session = try arm()
    events.removeAll()
    try engine.disarm(connectionID: connection, sessionID: session, reason: .user)
    XCTAssertEqual(events, [.journal(.restoring), .set(false), .read(false), .clearJournal])
}
```

- [ ] **Step 2: Write failure and recovery tests before implementation**

```swift
func testFailedRestoreKeepsJournalAndBlocksNewArm() throws {
    let session = try arm()
    pmset.setError = .commandFailed
    XCTAssertThrowsError(try engine.disarm(connectionID: connection, sessionID: session, reason: .batteryFloor))
    XCTAssertEqual(engine.status().state, .faulted)
    XCTAssertNotNil(try journal.load())
    XCTAssertThrowsError(try engine.arm(connectionID: connection, sample: safeBattery, floor: BatteryFloor(10)!))
}

func testLaunchRecoveryRestoresBeforeAcceptingWork() throws {
    try journal.save(activeJournal(original: false))
    pmset.observed = true
    try engine.recoverAtLaunch()
    XCTAssertEqual(pmset.observed, false)
    XCTAssertNil(try journal.load())
}

func testCorruptJournalFailsSafeToZeroAndRemainsFaulted() {
    journal.loadError = .corrupt
    pmset.observed = true
    XCTAssertThrowsError(try engine.recoverAtLaunch())
    XCTAssertFalse(pmset.observed)
    XCTAssertTrue(journal.corruptFileStillExists)
    XCTAssertEqual(engine.status().state, .faulted)
}

func testRenewAtFloorDisconnectAndLeaseExpiryRestore() throws {
    let session = try arm()
    XCTAssertThrowsError(try engine.renew(connectionID: connection, sessionID: session, sample: atFloor, floor: BatteryFloor(10)!))
    XCTAssertFalse(pmset.observed)

    let second = try arm()
    try engine.connectionInvalidated(connectionID: connection)
    XCTAssertFalse(pmset.observed)

    let third = try arm()
    monotonic.advance(by: 31)
    try engine.leaseExpired(now: monotonic.now)
    XCTAssertFalse(pmset.observed)
}
```

Also cover wrong session/connection IDs, duplicate disarm, external observed change
from 1 to 0, stale renewals, pmset verify mismatch, corrupt journal, and retry after
fault.

- [ ] **Step 3: Run the focused suite and verify red**

Run: `./build.sh test -only-testing:LidlessTests/HelperEngineTests`

Expected: FAIL because `HelperEngine` does not exist.

- [ ] **Step 4: Implement one serial, idempotent engine**

```swift
public final class HelperEngine: @unchecked Sendable {
    public func recoverAtLaunch() throws
    public func status() -> HelperStatus
    public func arm(connectionID: UUID, sample: PowerSample, floor: BatteryFloor) throws -> UUID
    public func renew(connectionID: UUID, sessionID: UUID, sample: PowerSample, floor: BatteryFloor) throws
    public func disarm(connectionID: UUID, sessionID: UUID, reason: DisarmReason) throws
    public func connectionInvalidated(connectionID: UUID) throws
    public func leaseExpired(now: TimeInterval) throws
    public func nextLeaseDeadline() -> TimeInterval?
}
```

Confine mutable state to one private serial queue. Persist `.activating` before
setting 1, `.active` after verification, and `.restoring` before restoration.
Unsafe renewals restore and return a cutoff error. If observed state changes to 0
during ownership, record `.externallyChanged`, clear the journal without writing
pmset, and end the session. A failed restore retains the journal and enters fault;
`recoverAtLaunch` and bounded retry call the same restoration primitive.

- [ ] **Step 5: Run focused/full tests under Thread Sanitizer once**

```bash
./build.sh test -only-testing:LidlessTests/HelperEngineTests
./build.sh test
xcodebuild -project .build/Lidless.xcodeproj -scheme Lidless -destination 'platform=macOS' test -enableThreadSanitizer YES CODE_SIGNING_ALLOWED=NO
```

Expected: PASS, 0 test failures and no sanitizer reports.

- [ ] **Step 6: Record evidence and commit**

```bash
git add Sources/LidlessCore/HelperEngine.swift Tests/LidlessTests/HelperEngineTests.swift STATUS.md CHANGELOG.md
git commit -m "feat: enforce helper lease and recovery state machine (#4)"
git push
```

### Task 6: Expose only an authenticated versioned XPC service

**Files:**
- Create: `Sources/LidlessCore/HelperProtocol.swift`
- Create: `Sources/LidlessCore/CodeSigningRequirements.swift`
- Create: `Sources/LidlessHelper/HelperService.swift`
- Replace: `Sources/LidlessHelper/main.swift`
- Create: `Tests/LidlessTests/ProtocolTests.swift`
- Create: `Tests/Fixtures/UnsignedHelperProbe.swift`
- Modify: `project.yml`
- Modify: `STATUS.md`

**Interfaces:**
- Produces: `LidlessHelperXPC`, `PowerSampleMessage`, `HelperStatusMessage`, `HelperReply`, `HelperListenerDelegate`.
- Consumes: `HelperEngine`; fixed requirement strings for app and helper.

- [ ] **Step 1: Write secure-coding and requirement tests**

```swift
func testPowerSampleMessageSecureCodingRoundTrip() throws {
    let original = PowerSampleMessage(source: .battery, percentage: 42, sampledAt: fixedDate, floor: 10)
    let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true)
    let decoded = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: PowerSampleMessage.self, from: data))
    XCTAssertEqual(decoded.sample, original.sample)
    XCTAssertEqual(decoded.floor, BatteryFloor(10)!)
}

func testRequirementsPinIdentifiersAndTeam() {
    XCTAssertEqual(CodeSigningRequirements.app, "identifier \"lv.ykv.lidless\" and anchor apple generic and certificate leaf[subject.OU] = \"J2Q78NFXZX\"")
    XCTAssertEqual(CodeSigningRequirements.helper, "identifier \"lv.ykv.lidless.helper\" and anchor apple generic and certificate leaf[subject.OU] = \"J2Q78NFXZX\"")
}

func testRejectsInvalidProtocolVersionAndOutOfRangeFields() {
    XCTAssertThrowsError(try PowerSampleMessage(validatingVersion: 2, sourceRaw: 99, percentage: 101, sampledAt: fixedDate, floor: 10))
}
```

- [ ] **Step 2: Run and verify red**

Run: `./build.sh test -only-testing:LidlessTests/ProtocolTests`

Expected: FAIL because XPC contracts do not exist.

- [ ] **Step 3: Implement the narrow protocol and per-connection service**

```swift
@objc public protocol LidlessHelperXPC {
    func status(reply: @escaping (HelperStatusMessage) -> Void)
    func arm(_ sample: PowerSampleMessage, reply: @escaping (HelperReply) -> Void)
    func renew(sessionID: NSUUID, sample: PowerSampleMessage, reply: @escaping (HelperReply) -> Void)
    func disarm(sessionID: NSUUID, reason: Int, reply: @escaping (HelperReply) -> Void)
    func removeRecognizedLegacyGrant(reply: @escaping (HelperReply) -> Void)
    func restoreNormalSleepAfterConfirmation(reply: @escaping (HelperReply) -> Void)
    func restartAfterVerifiedUpdateSwap(reply: @escaping (HelperReply) -> Void)
}
```

In `listener(_:shouldAcceptNewConnection:)`, call
`newConnection.setCodeSigningRequirement(CodeSigningRequirements.app)` before
setting interfaces or activating. Create a new `HelperSessionService` with a
random `connectionID`; its invalidation handler calls
`engine.connectionInvalidated(connectionID:)`. Configure `NSXPCInterface` allowed
classes explicitly for every DTO/reply position. The app will symmetrically pin
the helper requirement in Task 7.

Daemon bootstrap order is fixed:

```swift
let engine = HelperCompositionRoot.makeEngine()
try engine.recoverAtLaunch()
let listener = NSXPCListener(machServiceName: "lv.ykv.lidless.helper")
let delegate = HelperListenerDelegate(engine: engine)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
```

If recovery fails, log the fault and keep the daemon alive for retry/status, but
do not accept `arm`.

`HelperService` owns one `DispatchSourceTimer` on the engine queue. After each
successful arm/renew it schedules `engine.nextLeaseDeadline()`; when it fires it
calls `engine.leaseExpired(now:)`. In a faulted restore it retries after
1, 2, 4, 8, then 15 seconds (15-second cap) without clearing the journal. A new
renewal never cancels an already-started restore.

`restartAfterVerifiedUpdateSwap` succeeds only while inactive, with observed
normal sleep and no journal. It sends the reply, then exits with `EX_TEMPFAIL` so
launchd restarts the helper from the newly swapped app bundle. It accepts no path,
version, signal, or delay from XPC.

The fixture probe declares only the `status(reply:)` Objective-C selector, opens
the fixed privileged Mach service without a matching Team signature, sends one
message, and exits success only when XPC invalidates without a reply. It is not
linked into any shipping target.

- [ ] **Step 4: Run tests and inspect the built protocol surface**

```bash
./build.sh test -only-testing:LidlessTests/ProtocolTests
./build.sh test
./build.sh app
nm -gj Lidless.app/Contents/Library/HelperTools/LidlessHelper | rg 'system|popen|AuthorizationExecuteWithPrivileges' && exit 1 || true
plutil -lint Lidless.app/Contents/Library/LaunchDaemons/lv.ykv.lidless.helper.plist
```

Expected: tests/build/plist pass; forbidden generic execution symbols are absent.

- [ ] **Step 5: Record evidence and commit**

```bash
git add Sources/LidlessCore/HelperProtocol.swift Sources/LidlessCore/CodeSigningRequirements.swift Sources/LidlessHelper Tests/LidlessTests/ProtocolTests.swift project.yml STATUS.md
git commit -m "feat: authenticate the helper XPC boundary (#4)"
git push
```

### Task 7: Add event-driven battery sampling and lease coordination

**Files:**
- Create: `Sources/LidlessApp/BatteryMonitor.swift`
- Create: `Sources/LidlessApp/HelperClient.swift`
- Create: `Sources/LidlessCore/SafetyCoordinator.swift`
- Create: `Sources/LidlessApp/SafetyAdapters.swift`
- Create: `Tests/LidlessTests/SafetyCoordinatorTests.swift`
- Modify: `project.yml`
- Modify: `STATUS.md`

**Interfaces:**
- Produces: `PowerSampling`, `BatteryMonitoring`, `HelperControllingClient`, `ActivityManaging`, `RenewalScheduling`, and `SafetyCoordinator`.
- Consumes: core safety policy and XPC protocol.

- [ ] **Step 1: Write coordinator lifecycle tests with interface fakes**

```swift
func testArmSamplesImmediatelyThenStartsActivityAndRenewal() async throws {
    battery.next = sample(.battery, 42)
    try await coordinator.arm(floor: BatteryFloor(10)!)
    XCTAssertEqual(helper.calls, [.arm(sample(.battery, 42), BatteryFloor(10)!)])
    XCTAssertTrue(activity.isActive)
    XCTAssertEqual(scheduler.interval, 10)
}

func testExactFloorDisarmsWithoutRenewing() async throws {
    try await armAt(11, floor: 10)
    battery.next = sample(.battery, 10)
    await coordinator.powerDidChange()
    XCTAssertEqual(helper.calls.last, .disarm(.batteryFloor))
    XCTAssertFalse(activity.isActive)
}

func testRenewFailureEndsLocalOwnershipAndNotifies() async throws {
    try await armAt(80, floor: 10)
    helper.renewError = HelperClientError.connectionLost
    await coordinator.renewalFired()
    XCTAssertFalse(coordinator.isArmed)
    XCTAssertFalse(activity.isActive)
    XCTAssertEqual(notifier.events.last, .helperRecoveryPending)
}

func testFloorChangeEvaluatesImmediately() async throws {
    try await armAt(15, floor: 10)
    await coordinator.setFloor(BatteryFloor(20)!)
    XCTAssertEqual(helper.calls.last, .disarm(.batteryFloor))
}
```

- [ ] **Step 2: Run and verify red**

Run: `./build.sh test -only-testing:LidlessTests/SafetyCoordinatorTests`

Expected: FAIL because coordinator contracts do not exist.

- [ ] **Step 3: Implement monitor, signed client, activity, and common-mode timer**

`IOKitBatteryMonitor.sample()` must use `IOPSGetProvidingPowerSourceType`, prefer
an internal battery description, calculate clamped integer percentage, and return
`.unknown` rather than selecting the first arbitrary UPS/device. `start` registers
`IOPSNotificationCreateRunLoopSource` in `RunLoop.Mode.common`; `stop` removes and
releases it.

`XPCScheduledHelperClient` creates:

```swift
let connection = NSXPCConnection(machServiceName: "lv.ykv.lidless.helper", options: .privileged)
connection.setCodeSigningRequirement(CodeSigningRequirements.helper)
connection.remoteObjectInterface = HelperInterfaces.remote
connection.invalidationHandler = { [weak self] in self?.handleInvalidation() }
connection.activate()
```

`SafetyCoordinator.arm` evaluates locally, awaits verified helper arm, then takes
`ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
reason: "Lidless safety lease")` and starts a 10-second common-mode timer. Every
event/timer obtains a fresh sample. Stop timer/activity on all terminal paths.

- [ ] **Step 4: Run tests, build, and static checks**

```bash
./build.sh test -only-testing:LidlessTests/SafetyCoordinatorTests
./build.sh test
./build.sh app
! plutil -p Lidless.app/Contents/Info.plist | grep -q NSAppSleepDisabled
strings Lidless.app/Contents/MacOS/Lidless | grep -q 'lv.ykv.lidless.helper'
```

Expected: all pass; blanket App Nap disable is absent.

- [ ] **Step 5: Record evidence and commit**

```bash
git add Sources/LidlessApp/BatteryMonitor.swift Sources/LidlessApp/HelperClient.swift Sources/LidlessApp/SafetyAdapters.swift Sources/LidlessCore/SafetyCoordinator.swift Tests/LidlessTests/SafetyCoordinatorTests.swift project.yml STATUS.md
git commit -m "feat: monitor battery with an expiring safety lease (#4)"
git push
```

### Task 8: Integrate menu states, helper approval, quit, and legacy cleanup

**Files:**
- Create: `Sources/LidlessApp/MenuState.swift`
- Create: `Sources/LidlessApp/AppDelegate.swift`
- Create: `Sources/LidlessCore/LegacyGrantMigrator.swift`
- Create: `Tests/LidlessTests/LegacyGrantMigratorTests.swift`
- Replace: `Sources/LidlessApp/main.swift`
- Modify: `install.sh`
- Modify: `build.sh`
- Delete: `main.swift`
- Delete: `Info.plist`
- Modify: `README.md`
- Modify: `STATUS.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces: complete menu-bar app, visible helper lifecycle, custom verified Quit, exact legacy cleanup.
- Consumes: `SafetyCoordinator`, `SMAppService.daemon`, helper status/XPC.

- [ ] **Step 1: Write exact legacy-grant tests**

```swift
func testDeletesOnlyKnownHistoricalRulesAtKnownPaths() throws {
    for line in [
        "sashayakovlev ALL=(ALL) NOPASSWD: /usr/bin/pmset\n",
        "sashayakovlev ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
    ] {
        let file = try fixture(path: "/etc/sudoers.d/keepawake", contents: line, owner: .root, mode: 0o440)
        XCTAssertEqual(try migrator.removeIfRecognized(file), .removed)
    }
}

func testNeverDeletesEditedSymlinkWrongOwnerOrUnknownPath() throws {
    XCTAssertEqual(try migrator.removeIfRecognized(editedFixture), .manualCleanupRequired)
    XCTAssertEqual(try migrator.removeIfRecognized(symlinkFixture), .manualCleanupRequired)
    XCTAssertEqual(try migrator.removeIfRecognized(nonRootFixture), .manualCleanupRequired)
    XCTAssertEqual(try migrator.removeIfRecognized(otherPathFixture), .notEligible)
}
```

- [ ] **Step 2: Run and verify red**

Run: `./build.sh test -only-testing:LidlessTests/LegacyGrantMigratorTests`

Expected: FAIL because migrator does not exist.

- [ ] **Step 3: Implement exact migration and menu state mapping**

The migrator hardcodes only `/etc/sudoers.d/lidless` and
`/etc/sudoers.d/keepawake`, uses `lstat`, requires a regular root-owned file,
mode no broader than `0440`, a maximum 512 bytes, and one of the two normalized
rules in the test with a syntactically valid username token. It unlinks that path
directly; it never accepts a path or expected contents from XPC.

Map helper/service state to these exact menu states:

```swift
enum MenuSafetyState: Equatable {
    case off
    case armed(percent: Int?, onBattery: Bool)
    case externalKeepAwake
    case helperNotRegistered
    case helperApprovalRequired
    case restoring
    case fault(code: HelperFaultCode)
}
```

The toggle does not arm until `SMAppService.daemon(plistName:
"lv.ykv.lidless.helper.plist")` is `.enabled`. On `.notRegistered`, show a clear
confirmation then call `register()`. On `.requiresApproval`, keep toggle disabled
and open the correct System Settings Login Items pane only after the user clicks
the setup item. Never fall back to authorization scripts.

Replace the system terminate selector with `quitLidless`: request disarm, wait up
to 5 seconds for its reply, release app state, and terminate. On lost reply,
notify that 30-second helper recovery is pending before terminating.

After one successful arm/disarm round trip, call
`removeRecognizedLegacyGrant`; show manual instructions for unrecognized files.
Add **Uninstall helper…**: verified disarm, `SMAppService.unregister()`, then
preferences/state guidance.

Put that sequence in one `UninstallCoordinator` used by both the menu and a
bounded `--uninstall-helper` command-line mode. The command-line mode starts no
menu/UI: it connects to the fixed helper, disarms and verifies normal sleep,
requests recognized legacy cleanup, unregisters the fixed `SMAppService`, prints
one structured result line, and exits nonzero on partial cleanup. It accepts no
path, service name, pmset value, or extra argument; this is the Homebrew uninstall
entry point in the companion plan.

When `.externalKeepAwake` is shown, provide an explicit **Restore Normal Lid
Sleep…** action with a confirmation explaining that another tool may own the
setting. The helper performs this one fixed `pmset ... 0` action only after that
confirmation; it never does it automatically.

Use `Logger(subsystem: "lv.ykv.lidless", category:)` with fixed `battery`,
`helper`, `state`, and `update` categories. Log enum reason/result codes and
numeric battery/floor only. Post a local notification for battery cutoff,
helper-driven recovery discovered on reconnect, and restoration fault. Add
**Copy diagnostics** which copies a bounded rendered `DiagnosticSnapshot`
containing app/helper versions, service/status enums, current sample, configured
floor, observed boolean, and latest five Lidless error codes; no raw journal,
command output, username, or unrestricted path is included.

- [ ] **Step 4: Finish safe build/install wrappers**

`build.sh app` must generate, build Release for both architectures, copy the app
to repo root through a temporary sibling, and verify both app/helper slices.
Re-run the Task 1 `install.sh` rollback contract against the completed bundle and
require a non-ad-hoc Apple Development or Developer ID signature before attempting
helper registration. The installer does not remove any sudoers file itself.

- [ ] **Step 5: Run all automated proof and source assertions**

```bash
./build.sh test
./build.sh app
bash Tests/BuildContracts/test_project_layout.sh
rg -n 'sudo|osascript|administrator privileges|NSAppSleepDisabled' Sources Config build.sh install.sh && exit 1 || true
plutil -lint Config/Lidless-Info.plist Config/lv.ykv.lidless.helper.plist
lipo -archs Lidless.app/Contents/MacOS/Lidless
lipo -archs Lidless.app/Contents/Library/HelperTools/LidlessHelper
```

Expected: all tests/build/plists pass; both lipo results contain `x86_64 arm64`;
forbidden privilege fallbacks are absent.

- [ ] **Step 6: Update docs/proof and commit**

README must describe the signed helper and visible approval, remove every "No
daemon"/sudoers setup claim, explain external state and uninstall. Record full
test output summaries in `STATUS.md` and behavior in `CHANGELOG.md`.

```bash
git add project.yml Config Sources Tests build.sh install.sh README.md CHANGELOG.md STATUS.md
git add -u main.swift Info.plist
git commit -m "feat: integrate fail-safe helper lifecycle (#4)"
git push
```

### Task 9: Perform reversible live helper smoke verification

**Files:**
- Create: `Scripts/smoke-helper.sh`
- Modify: `STATUS.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces: repeatable evidence for arm, disarm, cutoff, force-quit, and helper restart.
- Consumes: signed Debug/Release app installed in `/Applications`, user-approved helper.

- [ ] **Step 1: Add a smoke script that records and restores baseline**

```bash
#!/bin/bash
set -euo pipefail
APP="/Applications/Lidless.app"
HELPER_LABEL="system/lv.ykv.lidless.helper"
baseline="$(pmset -g | awk 'tolower($1)=="sleepdisabled" {print $2}')"
test "$baseline" = 0
trap 'open -a Lidless >/dev/null 2>&1 || true' EXIT
test -d "$APP"
launchctl print "$HELPER_LABEL" >/dev/null
echo "baseline=$baseline helper=$HELPER_LABEL"
echo "Use the Debug-only Lidless smoke menu/URL commands for arm and simulated battery; every assertion below polls pmset with a 35-second hard deadline."
```

Complete the script with a small `wait_for_value expected timeout` function and
Debug-only app commands implemented behind `#if DEBUG` and a private distributed
notification name. Release compilation must have no simulation selector/string.
The script refuses to run unless baseline is 0, the exact app exists, and helper
registration is healthy. Its trap requests normal app launch; each scenario
explicitly verifies restoration before continuing.

- [ ] **Step 2: Build/install and pause for visible macOS approval if required**

Run:

```bash
./build.sh app
./install.sh
open 'x-apple.systempreferences:com.apple.LoginItems-Settings.extension'
```

Expected: Lidless appears in macOS background items. If approval is required,
stop only for the user's visible approval; do not automate it.

- [ ] **Step 3: Run the live matrix**

Run: `bash Scripts/smoke-helper.sh`

Expected evidence:

- arm changes observed value 0 -> 1;
- disarm changes 1 -> 0;
- simulated battery 11 -> 10 restores 0 immediately;
- `kill -TERM` of the app restores 0 within 30 seconds;
- `kill -KILL` of the app restores 0 within 30 seconds;
- killing the helper causes launchd recovery and restores 0;
- normal Quit restores 0;
- an unsigned/ad-hoc `Tests/Fixtures/UnsignedHelperProbe` connection is invalidated
  without receiving helper status;
- an incompatible protocol-version DTO is rejected without changing pmset;
- every scenario finishes at the original baseline.

- [ ] **Step 4: Re-run clean automation and inspect logs**

```bash
./build.sh test
./build.sh app
log show --last 10m --predicate 'subsystem == "lv.ykv.lidless"' --style compact | tail -200
git diff --check
```

Expected: green automation; logs contain bounded state/reason codes and no command
output, username, token, or unrelated path.

- [ ] **Step 5: Record evidence and commit**

```bash
git add Scripts/smoke-helper.sh STATUS.md CHANGELOG.md
git commit -m "test: prove live helper recovery paths (#4)"
git push
```

Do not close issue #4 yet; updater/release hardening remains in the companion plan.
