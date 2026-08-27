# Lidless Update and Release Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Lidless update staging and version 1.1.0 publication fail closed from download through notarized GitHub and Homebrew delivery.

**Architecture:** Pure core types validate versions, manifests, and mounted-image paths; an unprivileged app coordinator downloads a disk image into a private staging directory, mounts it read-only without Finder interaction, verifies the exact signed app identity before any replacement, disarms Lidless, and performs a same-directory atomic swap only when writable. Release scripts separate artifact construction from irreversible publication and require tests, universal slices, nested signatures, notarization, stapling, and Gatekeeper acceptance before GitHub/Homebrew mutation.

**Tech Stack:** Swift 6, Foundation URLSession, CryptoKit, Security `SecStaticCode`, AppKit/NSWorkspace, POSIX `renameatx_np`, Xcode command-line tools, notarytool, codesign, spctl, GitHub CLI, Homebrew.

**Spec:** `docs/superpowers/specs/2026-08-26-lidless-failsafe-helper-design.md`

## Global Constraints

- Execute only after `2026-08-26-lidless-failsafe-helper.md` is green, including live helper recovery.
- Target release is exactly `1.1.0`, Git tag `v1.1.0`, updater asset `Lidless.dmg`, direct/Homebrew asset `Lidless.zip`, and manifest `SHA256SUMS` covering both.
- Accept only bundle ID `lv.ykv.lidless`, Team ID `J2Q78NFXZX`, exact expected version, valid nested signature, hardened runtime, and Gatekeeper acceptance.
- Checksum is mandatory for in-app staging; missing or ambiguous manifest entries fail closed.
- Download under a unique mode-0700 temporary directory; mount only with fixed `hdiutil -readonly -verify -nobrowse -noautoopen` arguments under an empty private mount root, then detach on every path.
- Never pre-delete or overwrite `~/Downloads/Lidless.app` or any unrelated user file.
- The updater stays unprivileged and cannot reuse the pmset helper for file installation.
- Require verified helper disarm before replacing or revealing an update.
- If the installed directory is not writable, copy the verified disk image to a unique Downloads filename and require explicit manual installation.
- `release.sh build` has no remote side effects; only `release.sh publish` creates the GitHub release.
- GitHub publication and Homebrew promotion are performed by the main agent after all gates, never delegated.
- Landing links already point to `releases/latest`; verify them live but do not mutate the home-root pseudo-repository without a real content need.
- Maintain red-green-refactor, explicit staging, atomic commits/pushes, `STATUS.md`, `CHANGELOG.md`, and untracked `implementation-notes.md`.

## File Structure

```text
Sources/LidlessCore/SemanticVersion.swift          Strict release version
Sources/LidlessCore/UpdateManifest.swift           Exact SHA manifest parsing
Sources/LidlessCore/ReleaseDescriptor.swift         Fixed GitHub asset URLs
Sources/LidlessCore/MountedImagePolicy.swift       Read-only mount/candidate validation
Sources/LidlessCore/MountedUpdateSession.swift      Idempotent detach lifetime
Sources/LidlessCore/UpdateContracts.swift           Cross-target updater interfaces
Sources/LidlessApp/UpdateDownloader.swift          Bounded URLSession downloads
Sources/LidlessApp/UpdateStager.swift               Private disk-image attach/detach
Sources/LidlessApp/StaticCodeValidator.swift        Security/Gatekeeper identity checks
Sources/LidlessApp/AppReplacer.swift                Same-directory atomic swap/manual fallback
Sources/LidlessCore/UpdateCoordinator.swift         Testable ordered update state machine
Tests/LidlessTests/SemanticVersionTests.swift       Version comparison
Tests/LidlessTests/UpdateManifestTests.swift        Manifest ambiguity/integrity
Tests/LidlessTests/MountedImagePolicyTests.swift    Mount/symlink/top-level rules
Tests/LidlessTests/UpdateCoordinatorTests.swift     Ordered fail-closed workflow
Tests/BuildContracts/test_release_fail_closed.sh    Script regression assertions
Scripts/validate-release.sh                         Local artifact proof gate
release.sh                                           Build/publish separation
README.md                                            Update/helper behavior
CHANGELOG.md                                         Final 1.1.0 notes
STATUS.md                                            Full acceptance evidence
```

---

### Task 1: Validate versions and checksum manifests strictly

**Files:**
- Create: `Sources/LidlessCore/SemanticVersion.swift`
- Create: `Sources/LidlessCore/UpdateManifest.swift`
- Create: `Sources/LidlessCore/ReleaseDescriptor.swift`
- Create: `Tests/LidlessTests/SemanticVersionTests.swift`
- Create: `Tests/LidlessTests/UpdateManifestTests.swift`
- Modify: `STATUS.md`

**Interfaces:**
- Produces: `SemanticVersion.init(_:)`, `Comparable`, `UpdateManifest.expectedSHA256(for:)`, and `ReleaseDescriptor.init(version:)`.
- Consumes: ASCII release strings and bounded manifest text.

- [ ] **Step 1: Write failing version tests**

```swift
func testComparesNormalizedThreePartVersions() throws {
    XCTAssertLessThan(try SemanticVersion("1.0.1"), try SemanticVersion("1.1.0"))
    XCTAssertEqual(try SemanticVersion("v1.1.0"), try SemanticVersion("1.1.0"))
}

func testRejectsMalformedOrUnboundedVersions() {
    for value in ["1", "1.1", "1.1.0.0", "1.1.-1", "1.1.0/../../x", String(repeating: "1", count: 65)] {
        XCTAssertThrowsError(try SemanticVersion(value))
    }
}

func testReleaseDescriptorDerivesOnlyFixedGitHubAssets() throws {
    let release = ReleaseDescriptor(version: try SemanticVersion("1.1.0"))
    XCTAssertEqual(release.diskImageURL.absoluteString, "https://github.com/sshykvlv/lidless/releases/download/v1.1.0/Lidless.dmg")
    XCTAssertEqual(release.manifestURL.absoluteString, "https://github.com/sshykvlv/lidless/releases/download/v1.1.0/SHA256SUMS")
}
```

- [ ] **Step 2: Write failing exact-manifest tests**

```swift
func testReturnsOneExactLowercaseSHAForLidlessDMG() throws {
    let hash = String(repeating: "a", count: 64)
    let manifest = try UpdateManifest("\(hash)  Lidless.dmg\n")
    XCTAssertEqual(try manifest.expectedSHA256(for: "Lidless.dmg"), hash)
}

func testRejectsMissingDuplicateMalformedAndOversizedManifest() {
    XCTAssertThrowsError(try UpdateManifest("").expectedSHA256(for: "Lidless.dmg"))
    let h = String(repeating: "b", count: 64)
    XCTAssertThrowsError(try UpdateManifest("\(h)  Lidless.dmg\n\(h)  Lidless.dmg\n").expectedSHA256(for: "Lidless.dmg"))
    XCTAssertThrowsError(try UpdateManifest("xyz  Lidless.dmg\n"))
    XCTAssertThrowsError(try UpdateManifest(String(repeating: "x", count: 65_537)))
}
```

- [ ] **Step 3: Run and verify red**

Run:

```bash
./build.sh test -only-testing:LidlessTests/SemanticVersionTests
./build.sh test -only-testing:LidlessTests/UpdateManifestTests
```

Expected: FAIL because both core types are missing.

- [ ] **Step 4: Implement exact bounded parsers**

```swift
public struct SemanticVersion: Comparable, Equatable, Sendable {
    public let major: UInt16
    public let minor: UInt16
    public let patch: UInt16
    public init(_ raw: String) throws
}

public struct UpdateManifest: Sendable {
    public init(_ text: String) throws
    public func expectedSHA256(for exactFilename: String) throws -> String
}

public struct ReleaseDescriptor: Equatable, Sendable {
    public let version: SemanticVersion
    public let diskImageURL: URL
    public let manifestURL: URL
    public init(version: SemanticVersion)
}
```

Allow one optional leading `v`, exactly three decimal components, no whitespace,
and a maximum raw length of 64. Manifest input is at most 64 KiB; each nonempty
line is exactly 64 hex characters, whitespace, then a basename without `/`, `\\`,
or control characters. The in-app path requires exactly one `Lidless.dmg` entry;
release validation separately requires exactly one `Lidless.zip` entry too.

- [ ] **Step 5: Run tests and commit evidence**

```bash
./build.sh test -only-testing:LidlessTests/SemanticVersionTests
./build.sh test -only-testing:LidlessTests/UpdateManifestTests
./build.sh test
git add Sources/LidlessCore/SemanticVersion.swift Sources/LidlessCore/UpdateManifest.swift Sources/LidlessCore/ReleaseDescriptor.swift Tests/LidlessTests/SemanticVersionTests.swift Tests/LidlessTests/UpdateManifestTests.swift STATUS.md
git commit -m "feat: validate update versions and manifests (#4)"
git push
```

### Task 2: Mount the update disk image read-only in a private directory

**Files:**
- Create: `Sources/LidlessCore/MountedImagePolicy.swift`
- Create: `Sources/LidlessCore/MountedUpdateSession.swift`
- Create: `Sources/LidlessCore/UpdateContracts.swift`
- Create: `Sources/LidlessApp/UpdateDownloader.swift`
- Create: `Sources/LidlessApp/UpdateStager.swift`
- Create: `Tests/LidlessTests/MountedImagePolicyTests.swift`
- Modify: `project.yml`
- Modify: `STATUS.md`

**Interfaces:**
- Produces: `MountedImagePolicy.validate`, `BoundedDownloader`, `DiskImageAttaching`, and `UpdateStager.stage(diskImage:version:)`.
- Consumes: exact release disk-image URL, private staging/mount roots, injected fixed command runner for `/usr/bin/hdiutil`.

- [ ] **Step 1: Write failing mounted-image policy tests**

```swift
func testAcceptsOneReadOnlyRootLidlessBundle() throws {
    let mount = MountedImageDescription(
        device: "/dev/disk42", mountPoint: privateMountRoot.appendingPathComponent("Lidless"), isReadOnly: true,
        rootEntries: ["Lidless.app"]
    )
    XCTAssertNoThrow(try MountedImagePolicy.validate(
        mount: mount, expectedMountRoot: privateMountRoot,
        candidate: mount.mountPoint.appendingPathComponent("Lidless.app"),
        candidateKind: .directory, resolvedCandidate: mount.mountPoint.appendingPathComponent("Lidless.app")
    ))
}

func testRejectsWritableWrongMountpointExtraRootSymlinkAndEscape() {
    XCTAssertThrowsError(try validate(mount(readOnly: false)))
    XCTAssertThrowsError(try validate(mount(mountPoint: outside)))
    XCTAssertThrowsError(try validate(mount(rootEntries: ["Lidless.app", "payload.sh"])))
    XCTAssertThrowsError(try validate(mount(), candidateKind: .symbolicLink))
    XCTAssertThrowsError(try validate(mount(), resolvedCandidate: outside.appendingPathComponent("Lidless.app")))
}

func testMountedSessionDetachesExactlyOnce() throws {
    var detachCount = 0
    let session = makeSession { detachCount += 1 }
    try session.detach()
    try session.detach()
    XCTAssertEqual(detachCount, 1)
}
```

- [ ] **Step 2: Run and verify red**

Run: `./build.sh test -only-testing:LidlessTests/MountedImagePolicyTests`

Expected: FAIL because mounted-image policy is missing.

- [ ] **Step 3: Implement bounded download and read-only attach/detach**

```swift
public protocol UpdateDownloading: AnyObject {
    func download(_ request: URLRequest, maximumBytes: Int64) async throws -> URL
    func text(_ request: URLRequest, maximumBytes: Int) async throws -> String
}

public final class MountedUpdateSession: @unchecked Sendable {
    public let root: URL
    public let diskImage: URL
    public let app: URL
    public let version: SemanticVersion
    private let detachAction: @Sendable () throws -> Void
    public init(root: URL, diskImage: URL, app: URL, version: SemanticVersion,
                detachAction: @escaping @Sendable () throws -> Void)
    public func detach() throws
}

protocol DiskImageAttaching: AnyObject {
    func attachReadOnly(image: URL, mountRoot: URL) throws -> MountedImageDescription
    func detach(device: String) throws
}

public protocol UpdateStaging: AnyObject {
    func mount(diskImage: URL, version: SemanticVersion) throws -> MountedUpdateSession
}
```

`BoundedDownloader` accepts HTTPS only, a 30-second request timeout, at most 32 MiB
for `Lidless.dmg`, at most 64 KiB for `SHA256SUMS`, rejects non-2xx and redirects
to non-HTTPS, userinfo-bearing, non-443, loopback, link-local, or `.local`
destinations. Requests originate only from `ReleaseDescriptor` fixed GitHub URLs,
follow at most five redirects, carry no credential header, and count actual
received bytes rather than trusting `Content-Length`.

`UpdateStager` creates a unique directory beneath `FileManager.default.temporaryDirectory`
with mode `0700`, including an empty `mount` child. It streams SHA-256 for the disk
image, then runs only:

```text
/usr/bin/hdiutil attach <image> -readonly -verify -nobrowse -noautoopen -owners off -mountroot <mounts> -plist
```

Parse bounded property-list output and require exactly one entity containing a
mount point; non-mounted container-device entities are allowed, but a second
mounted volume is not. Require that mounted entity's resolved mountpoint to be a
strict child of the expected private mount root and retain its `dev-entry` for
detach.
Confirm `MNT_RDONLY` with `statfs`, list the mounted volume root without
recursion, require exactly one real directory named `Lidless.app`, reject a
symlink or a resolved candidate outside the mount, and cap the candidate at 128
MiB while walking without following symlinks. It returns a
`MountedUpdateSession` whose thread-safe `detach()` executes exactly once using
fixed `/usr/bin/hdiutil detach <device>`. If normal detach fails, retry once after
1 second without `-force`, report cleanup failure, and retain the private root for
diagnosis. `UpdateCoordinator` calls `detach()` on every success/error path and
does not disarm or touch the installed app if detach fails. Cleanup deletes only
its captured resolved temp root after confirming it remains below the system temp
directory.

- [ ] **Step 4: Run tests and mount a generated read-only fixture image**

```bash
./build.sh test -only-testing:LidlessTests/MountedImagePolicyTests
./build.sh test
fixture_dir="$(mktemp -d)"
mkdir -p "$fixture_dir/staging/Lidless.app/Contents/MacOS"
touch "$fixture_dir/staging/Lidless.app/Contents/MacOS/Lidless"
hdiutil create -srcfolder "$fixture_dir/staging" -format UDZO -volname Lidless "$fixture_dir/Lidless.dmg"
mount_dir="$(mktemp -d)"
hdiutil attach "$fixture_dir/Lidless.dmg" -readonly -verify -nobrowse -noautoopen -owners off -mountroot "$mount_dir"
mounted_volume="$(find "$mount_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)"
test -d "$mounted_volume/Lidless.app"
hdiutil detach "$mounted_volume"
```

Expected: tests pass, the image mounts read-only with only `Lidless.app`, and
detach succeeds.

- [ ] **Step 5: Record evidence and commit**

```bash
git add Sources/LidlessCore/MountedImagePolicy.swift Sources/LidlessCore/MountedUpdateSession.swift Sources/LidlessCore/UpdateContracts.swift Sources/LidlessApp/UpdateDownloader.swift Sources/LidlessApp/UpdateStager.swift Tests/LidlessTests/MountedImagePolicyTests.swift project.yml STATUS.md
git commit -m "feat: mount updates read-only before validation (#4)"
git push
```

### Task 3: Verify signed identity before an atomic app replacement

**Files:**
- Create: `Sources/LidlessApp/StaticCodeValidator.swift`
- Create: `Sources/LidlessApp/AppReplacer.swift`
- Create: `Sources/LidlessCore/UpdateCoordinator.swift`
- Create: `Tests/LidlessTests/UpdateCoordinatorTests.swift`
- Modify: `Sources/LidlessApp/AppDelegate.swift`
- Modify: `Sources/LidlessCore/UpdateContracts.swift`
- Delete updater implementation from: legacy/new `AppDelegate` locations
- Modify: `STATUS.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces: `StagedAppValidating.validate(app:expectedVersion:)`, `AppReplacing.prepare`, `commit`, `rollback`, `cleanup`, and `UpdateCoordinator`.
- Consumes: `UpdateDownloading`, `UpdateStaging`, `MountedUpdateSession`, verified helper disarm/restart, fixed bundle/team requirements.

- [ ] **Step 1: Write the ordered fail-closed coordinator tests**

```swift
func testValidUpdateOrdersChecksumStageIdentityDisarmReplaceLaunch() async throws {
    try await coordinator.install(release, installedApp: installedApp)
    XCTAssertEqual(events, [
        .downloadManifest, .downloadDiskImage, .verifyChecksum, .mountReadOnly,
        .validateIdentity(version: "1.1.0"), .prepareReplacement, .detach,
        .disarm, .commitSwap,
        .restartHelper, .launchNewInstance, .confirmNewProcess
    ])
}

func testIdentityFailureNeverDisarmsOrTouchesInstalledApp() async {
    validator.error = .wrongTeam
    do {
        try await coordinator.install(release, installedApp: installedApp)
        XCTFail("Expected wrong-team rejection")
    } catch {}
    XCTAssertFalse(events.contains(.disarm))
    XCTAssertFalse(events.contains(.prepareReplacement))
    XCTAssertTrue(events.contains(.detach))
}

func testDisarmFailureNeverReplaces() async {
    helper.disarmError = .verificationMismatch
    do {
        try await coordinator.install(release, installedApp: installedApp)
        XCTFail("Expected verified-disarm failure")
    } catch {}
    XCTAssertFalse(events.contains(.commitSwap))
    XCTAssertTrue(events.contains(.cleanupPreparedUpdate))
}

func testUnwritableApplicationsFallsBackToUniqueDiskImageWithoutDeletion() async throws {
    replacer.result = .manualInstall(verifiedDiskImageURL)
    try await coordinator.install(release, installedApp: installedApp)
    XCTAssertEqual(ui.revealedURL, verifiedDiskImageURL)
    XCTAssertFalse(fileSystem.deletedURLs.contains(downloads.appendingPathComponent("Lidless.app")))
}

func testDetachFailureNeverDisarmsOrCommits() async {
    mountedSession.detachError = .detachFailed
    do {
        try await coordinator.install(release, installedApp: installedApp)
        XCTFail("Expected detach failure")
    } catch {}
    XCTAssertFalse(events.contains(.disarm))
    XCTAssertFalse(events.contains(.commitSwap))
}
```

Also test missing checksum asset, wrong version, bundle ID, Team ID, signature,
hardened-runtime flag, Gatekeeper failure, replacement-copy revalidation failure,
launch failure, and cancellation cleanup.

- [ ] **Step 2: Run and verify red**

Run: `./build.sh test -only-testing:LidlessTests/UpdateCoordinatorTests`

Expected: FAIL because coordinator/validator/replacer do not exist.

- [ ] **Step 3: Implement Security-framework identity validation**

```swift
public protocol StagedAppValidating: AnyObject {
    func validate(app: URL, expectedVersion: SemanticVersion) throws
}

final class StaticCodeValidator: StagedAppValidating {
    static let requirement = CodeSigningRequirements.app
    func validate(app: URL, expectedVersion: SemanticVersion) throws
}
```

Require a regular non-symlink `.app`; read bundle ID/version from the staged
bundle; create `SecStaticCode`; create the fixed requirement string; call
`SecStaticCodeCheckValidityWithErrors` with `.checkAllArchitectures`, inspect
signing information for Team ID and runtime flag, and run fixed
`/usr/sbin/spctl --assess --type execute --verbose=2 app`. Any missing property,
nonzero status, timeout, or ambiguous output is failure.

- [ ] **Step 4: Implement same-directory swap and manual fallback**

Define the preparation boundary in `LidlessCore`:

```swift
public enum PreparedInstall: Sendable {
    case replacement(PreparedReplacement)
    case manualInstall(diskImage: URL)
}

public struct PreparedReplacement: Sendable {
    public let installedApp: URL
    public let stagedSibling: URL
    public let version: SemanticVersion
    public init(installedApp: URL, stagedSibling: URL, version: SemanticVersion)
}

public struct ReplacementReceipt: Sendable {
    public let installedApp: URL
    public let oldAppSibling: URL
    public let version: SemanticVersion
    public init(installedApp: URL, oldAppSibling: URL, version: SemanticVersion)
}

public protocol AppReplacing: AnyObject {
    func prepare(mountedApp: URL, diskImage: URL, installedApp: URL,
                 version: SemanticVersion, expectedDiskImageSHA256: String) throws -> PreparedInstall
    func commit(_ replacement: PreparedReplacement) throws -> ReplacementReceipt
    func rollback(_ receipt: ReplacementReceipt) throws
    func cleanup(_ prepared: PreparedInstall) throws
}

public protocol UpdateHelperControlling: AnyObject {
    func disarmForUpdate() async throws
    func restartAfterVerifiedUpdateSwap() async throws
}

public protocol UpdatedAppLaunching: AnyObject {
    func launchNewInstance(app: URL, expectedVersion: SemanticVersion) async throws -> Int32
}

public enum UpdateFailureCode: Int, Equatable, Sendable {
    case network, manifest, checksum, mount, identity, detach, disarm,
         prepare, swap, helperRestart, launch, rollback, cleanup
}

public enum UpdatePhase: Equatable, Sendable {
    case checking
    case downloading(SemanticVersion)
    case verifying(SemanticVersion)
    case mounting(SemanticVersion)
    case preparing(SemanticVersion)
    case installing(SemanticVersion)
    case manualInstall(URL)
    case finished(SemanticVersion)
    case failed(UpdateFailureCode)
}

@MainActor public protocol UpdateReporting: AnyObject {
    func updatePhaseChanged(_ phase: UpdatePhase)
}

public final class UpdateCoordinator {
    public init(downloader: UpdateDownloading, stager: UpdateStaging,
                validator: StagedAppValidating, replacer: AppReplacing,
                helper: UpdateHelperControlling, launcher: UpdatedAppLaunching,
                reporter: UpdateReporting)
    public func install(_ release: ReleaseDescriptor, installedApp: URL) async throws
}
```

When the installed parent is writable, copy the already verified app into a
unique hidden sibling such as `.Lidless.update-<UUID>.app`, reject symlinks during
copy with fixed `/usr/bin/ditto`, re-run `StaticCodeValidator` on the sibling,
then use
`renameatx_np(..., RENAME_SWAP)` to atomically swap it with the installed path.
The old running bundle remains at the hidden sibling. After the swap, request the
fixed helper `restartAfterVerifiedUpdateSwap`; launch the installed URL with
`NSWorkspace.OpenConfiguration.createsNewApplicationInstance = true`; require a
new PID with bundle ID `lv.ykv.lidless`, expected version, and bundle URL equal to
the installed path within 10 seconds. Only then may the old process terminate.
The new process removes only the exact captured sibling recorded before launch,
after validating its parent, generated prefix, non-symlink type, and signed old
Lidless bundle. If helper restart or new-process confirmation fails, swap back,
request one helper restart from the restored app, and report failure.

When the parent is not writable, copy the verified disk image
to the first unused `~/Downloads/Lidless-v1.1.0[-N].dmg`, verify its SHA again,
reveal it, and leave the installed app untouched.

`UpdateCoordinator` must finish preparation while the image is mounted, then
detach successfully before requesting helper disarm. On pre-commit failure it
calls `cleanup`; on post-commit failure it calls `rollback`, requests one fixed
helper restart from the restored bundle, and then cleans up. A cleanup/rollback
failure is surfaced as a compound error and is never hidden by the original
failure.

- [ ] **Step 5: Integrate the menu without blocking the main thread**

Replace synchronous semaphore/network/process updater code with an async
`UpdateCoordinator`. Menu states are `checking`, `available(version)`,
`downloading`, `verifying`, `mounting`, `installing`, `manualInstall`, and `failed(code)`.
All UI mutation runs on `MainActor`; downloads, hashing, mounting, and signature
checks run off the main actor. The latest-release parser accepts only the exact
`Lidless.dmg` and required `SHA256SUMS` assets for in-app installation.
It fetches at most 64 KiB from the fixed GitHub API URL, reads only `tag_name`,
parses `SemanticVersion`, and derives both asset URLs with `ReleaseDescriptor`;
it never trusts `browser_download_url` or falls back to the first matching asset.

- [ ] **Step 6: Run focused/full tests and source checks**

```bash
./build.sh test -only-testing:LidlessTests/UpdateCoordinatorTests
./build.sh test
./build.sh app
rg -n 'Downloads.*Lidless\.app|removeItem.*Lidless\.app|DispatchSemaphore|first.*asset' Sources && exit 1 || true
codesign --verify --deep --strict Lidless.app
```

Expected: all pass; dangerous legacy patterns are absent.

- [ ] **Step 7: Record evidence and commit**

```bash
git add Sources/LidlessApp Sources/LidlessCore/UpdateCoordinator.swift Tests/LidlessTests/UpdateCoordinatorTests.swift STATUS.md CHANGELOG.md
git commit -m "fix: verify updates before atomic replacement (#4)"
git push
```

### Task 4: Make artifact creation and publication fail closed

**Files:**
- Create: `Scripts/validate-release.sh`
- Create: `Tests/BuildContracts/test_release_fail_closed.sh`
- Replace: `release.sh`
- Modify: `build.sh`
- Modify: `STATUS.md`

**Interfaces:**
- Produces: `./release.sh build 1.1.0 keepawake-notary` and `./release.sh publish 1.1.0`.
- Consumes: clean tested tree, Developer ID identity, notary profile, GitHub CLI auth.

- [ ] **Step 1: Write the failing release-script contract**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
grep -q 'case "$command" in' release.sh
grep -q 'build)' release.sh
grep -q 'publish)' release.sh
if rg -n 'spctl[^\n]*(\|\| true|set \+e)' release.sh Scripts/validate-release.sh; then
  echo "Gatekeeper validation can be ignored" >&2
  exit 1
fi
grep -q 'notarytool.*--wait' release.sh
grep -q 'gh release create' release.sh
```

- [ ] **Step 2: Run and verify red**

Run: `bash Tests/BuildContracts/test_release_fail_closed.sh`

Expected: FAIL because current `release.sh` has no build/publish split and ignores
Gatekeeper failure.

- [ ] **Step 3: Implement the local validation gate**

`Scripts/validate-release.sh APP VERSION` performs and exits nonzero on every
failed assertion:

```bash
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = "lv.ykv.lidless"
test "$(lipo -archs "$app/Contents/MacOS/Lidless")" = "x86_64 arm64" -o "$(lipo -archs "$app/Contents/MacOS/Lidless")" = "arm64 x86_64"
codesign --verify --deep --strict --verbose=2 "$app"
spctl --assess --type execute --verbose=3 "$app"
xcrun stapler validate "$app"
```

Repeat universal/signature/Team ID checks for
`Contents/Library/HelperTools/LidlessHelper`, validate the launchd plist and Mach
service, require runtime flags/timestamp, and scan for forbidden sudoers/osascript
strings. Compare Team IDs by parsing `codesign -dvv` bounded output.

- [ ] **Step 4: Implement separate build and publish commands**

`release.sh build`:

1. Requires exact version `1.1.0`, clean tracked worktree, Developer ID identity,
   notary profile, and green `./build.sh test`.
2. Builds unsigned universal products into a unique temp root.
3. Signs the helper first, then app, with hardened runtime and timestamp.
4. Verifies signatures before submission.
5. Creates a temporary notarization zip, submits with `--wait`, and requires an
   `Accepted` result.
6. Staples the app and runs `Scripts/validate-release.sh`.
7. Creates `dist/Lidless.dmg`, `dist/Lidless.zip`, and `dist/SHA256SUMS` through
   temp siblings. The DMG contains exactly one root app and the ZIP is the direct/
   Homebrew artifact. Verify both manifest entries and print paths. It performs no
   `git push` or `gh release` call.

`release.sh publish`:

1. Requires exact tag absent locally/remotely, clean tree, exact
   `HEAD == origin/main` (a detached release worktree is allowed), authenticated
   `gh`, and existing dist assets.
2. Re-mounts the DMG read-only and re-extracts the locally built ZIP into separate
   private roots, then runs `Scripts/validate-release.sh` plus checksum verification
   on both app candidates.
3. Creates annotated tag `v1.1.0`, pushes it, and runs:

```bash
gh release create v1.1.0 dist/Lidless.dmg dist/Lidless.zip dist/SHA256SUMS \
  --title 'Lidless 1.1.0' --notes-file dist/RELEASE_NOTES.md
```

4. Fetches the immutable published assets back into a new temp directory and
   verifies SHA-256 equality before reporting GitHub publication complete.

- [ ] **Step 5: Run contract and expected-negative local validation**

```bash
bash Tests/BuildContracts/test_release_fail_closed.sh
./build.sh test
./build.sh app
if Scripts/validate-release.sh Lidless.app 1.1.0; then
  echo 'Unexpected: local non-notarized build passed release validation' >&2
  exit 1
else
  echo 'Expected: non-notarized local build rejected'
fi
```

Expected: script contract/tests pass; local development build fails the final
notarization/Gatekeeper release gate.

- [ ] **Step 6: Record evidence and commit**

```bash
git add Scripts/validate-release.sh Tests/BuildContracts/test_release_fail_closed.sh release.sh build.sh STATUS.md
git commit -m "build: fail closed before Lidless publication (#4)"
git push
```

### Task 5: Complete documentation, security review, and PR verification

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `STATUS.md`
- Create: `dist/RELEASE_NOTES.md` (generated/committed release notes; other dist files ignored)
- Modify: `.gitignore`

**Interfaces:**
- Produces: reviewable branch/PR with acceptance evidence and exact release notes.
- Consumes: all code and test evidence from both plans.

- [ ] **Step 1: Finalize documentation against actual behavior**

README must document helper approval, 10/20/30/off battery choices, 30-second
failure recovery, external keep-awake detection, helper uninstall, secure updater,
macOS 13+, universal/notarized build, and source build dependencies including
XcodeGen. Remove all claims of no daemon, password dialogs, or sudoers setup.

`CHANGELOG.md` 1.1.0 lists fail-safe helper, exact threshold, crash/quit/reboot
recovery, no recurring password, update hardening, and migration. `STATUS.md`
maps every issue #4 checkbox to a test/command/result. `dist/RELEASE_NOTES.md`
contains concise user-facing notes and the visible one-time approval step.

- [ ] **Step 2: Run the complete deterministic gate**

```bash
./build.sh test
./build.sh app
bash Tests/BuildContracts/test_project_layout.sh
bash Tests/BuildContracts/test_release_fail_closed.sh
git diff --check origin/main...HEAD
rg -n 'BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|gho_|API_KEY=' --glob '!docs/**' . && exit 1 || true
if command -v gitleaks >/dev/null; then gitleaks git --log-opts='origin/main..HEAD'; fi
```

Expected: all gates pass and secret scan is empty.

- [ ] **Step 3: Perform an adversarial code/security review**

Review the full `origin/main...HEAD` diff against these explicit failure scenarios:

- forged XPC client/helper and protocol confusion;
- helper crash between journal and pmset mutation;
- failure to restore after app/helper kill or reboot;
- external `SleepDisabled` ownership conflict;
- writable/extra-root/symlinked disk image mount or duplicate manifest;
- wrong Team ID/bundle/version or valid signature without notarization;
- partial atomic swap, failed relaunch, unwritable `/Applications`;
- release script continuing after any failed gate.

Classify findings HIGH/MED/LOW. Fix every HIGH/MED with another red-green cycle;
run the complete gate again. Stop after at most two challenge rounds and require
zero HIGH findings before PR.

- [ ] **Step 4: Commit docs and open the PR**

```bash
git add README.md CHANGELOG.md STATUS.md dist/RELEASE_NOTES.md .gitignore
git commit -m "docs: prepare Lidless 1.1.0 safety release (#4)"
git push
gh pr create --base main --head fix/failsafe-cutoff \
  --title 'Lidless 1.1.0: fail-safe battery cutoff' \
  --body-file STATUS.md
```

Do not merge until CI/local evidence is green and the review has no HIGH finding.

### Task 6: Build, publish, update Homebrew, and verify live delivery

**Files:**
- Modify in `sshykvlv/homebrew-tap`: `Casks/lidless.rb`
- Modify in `sshykvlv/homebrew-tap`: `README.md`
- Update: GitHub release/tag and issue #4 state
- Verify only: `/Users/sashayakovlev/dev/lidless/index.html`, `llms.txt`, and live `https://lidless.ykv.lv`

**Interfaces:**
- Produces: notarized GitHub v1.1.0 and matching Homebrew cask.
- Consumes: merged main, release credentials, immutable DMG/ZIP SHA-256 values.

- [ ] **Step 1: Merge only the verified PR and sync clean main**

Fetch the merged commit, then build from a fresh detached release worktree so the
user's original checkout and its unrelated local changes remain untouched:

```bash
gh pr checks --watch
gh pr merge --merge --delete-branch=false
git fetch origin
release_parent="$(mktemp -d /tmp/lidless-release.XXXXXX)"
release_worktree="$release_parent/worktree"
git worktree add --detach "$release_worktree" origin/main
git -C "$release_worktree" status --short
```

Expected: checks green, clean detached worktree at exact `origin/main`, exact
merged implementation. Do not use a destructive reset or switch the user's
original checkout.

- [ ] **Step 2: Build the production artifact and inspect proof**

Run:

```bash
git -C "$release_worktree" rev-parse HEAD
cd "$release_worktree"
./release.sh build 1.1.0 keepawake-notary
shasum -a 256 -c dist/SHA256SUMS
Scripts/validate-release.sh Lidless.app 1.1.0
```

Expected: notary accepted, staple valid, Gatekeeper accepted, signatures/team IDs
and both universal binaries verified.

- [ ] **Step 3: Perform the final reversible installed-app smoke**

Install the exact `dist/Lidless.dmg` build, approve the helper visibly if required,
and rerun `Scripts/smoke-helper.sh`; separately extract and validate the exact ZIP
used by Homebrew. Record original app path and
`SleepDisabled` before installation. Verify all scenarios and restore the original
system value. This step may replace the prior local app but keeps a recoverable
backup until the new app passes.

- [ ] **Step 4: Publish GitHub and verify downloaded bytes**

Run: `./release.sh publish 1.1.0`

Expected: tag/release `v1.1.0`, both assets downloadable, published SHA matches
local `dist/SHA256SUMS`, latest-release API returns `v1.1.0`.

- [ ] **Step 5: Update Homebrew on its own feature branch**

In `/Users/sashayakovlev/dev/homebrew-tap`:

```bash
git fetch origin
git switch -c fix/lidless-1.1.0 origin/main
```

Set `version "1.1.0"` and the published SHA. Replace the sudoers-only zap claim
with the official `uninstall script:` DSL invoking the bounded user-context app
cleanup command before the app artifact is removed:

```ruby
uninstall script: {
  executable: "#{appdir}/Lidless.app/Contents/MacOS/Lidless",
  args:       ["--uninstall-helper"],
}

zap trash: [
  "~/Library/Caches/lv.ykv.lidless",
  "~/Library/Preferences/lv.ykv.lidless.plist",
  "~/Library/Saved Application State/lv.ykv.lidless.savedState",
]
```

Do not use `sudo: true`: the app connects to the already authenticated helper,
then unregisters `SMAppService` in the console user's context. If the bounded
cleanup returns nonzero, Homebrew must report failure rather than claiming the
helper was removed. README caveats give manual instructions only for edited or
unrecognized legacy sudoers files.

Run:

```bash
brew audit --cask Casks/lidless.rb
brew style Casks/lidless.rb
brew fetch --cask ./Casks/lidless.rb
git diff --check
git add Casks/lidless.rb README.md
git commit -m 'fix: update Lidless cask to 1.1.0 (#4)'
git push -u origin fix/lidless-1.1.0
gh pr create --base main --head fix/lidless-1.1.0 --title 'Update Lidless to 1.1.0' --body 'Uses the notarized v1.1.0 archive and published SHA-256.'
gh pr checks --watch
gh pr merge --merge
```

- [ ] **Step 6: Verify public install paths and close the issue with evidence**

Verify:

```bash
curl -fsSL https://api.github.com/repos/sshykvlv/lidless/releases/latest | jq -r .tag_name
curl -fsSI https://github.com/sshykvlv/lidless/releases/latest/download/Lidless.dmg | head
curl -fsSI https://github.com/sshykvlv/lidless/releases/latest/download/Lidless.zip | head
curl -fsSL https://raw.githubusercontent.com/sshykvlv/homebrew-tap/main/Casks/lidless.rb | rg '1\.1\.0'
curl -fsSL https://lidless.ykv.lv | rg 'releases/latest/download/Lidless.zip'
```

Expected: `v1.1.0`, successful asset response, cask 1.1.0, and live landing download
link. Add the final command/test/notary/SHA evidence to issue #4, then close it.

```bash
gh issue close 4 --comment 'Released in v1.1.0. Verified: automated tests, live arm/disarm and forced-termination recovery, notarization/Gatekeeper, published SHA-256, Homebrew cask, and landing download.'
```
