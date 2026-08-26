import Foundation
import XCTest

@testable import LidlessCore

@MainActor
final class UpdateCoordinatorTests: XCTestCase {
  func testValidUpdateOrdersChecksumStageIdentityDisarmReplaceLaunch() async throws {
    let fixture = try Fixture()

    try await fixture.coordinator.install(fixture.release, installedApp: fixture.installedApp)

    XCTAssertEqual(
      fixture.events.values,
      [
        .downloadManifest, .downloadDiskImage, .verifyChecksum, .mountReadOnly,
        .validateIdentity("1.1.0"), .prepareReplacement, .detach, .disarm, .commitSwap,
        .restartHelper, .launchNewInstance, .confirmNewProcess,
      ]
    )
    let phases = fixture.reporter.phases
    XCTAssertEqual(phases.last, .finished(try SemanticVersion("1.1.0")))
    XCTAssertEqual(fixture.downloader.removedFiles, [fixture.downloadedDiskImage])
  }

  func testIdentityFailureNeverDisarmsOrTouchesInstalledApp() async throws {
    let fixture = try Fixture()
    fixture.validator.error = StubError.failure

    await assertThrowsAsyncError(
      try await fixture.coordinator.install(fixture.release, installedApp: fixture.installedApp)
    )

    XCTAssertFalse(fixture.events.values.contains(.disarm))
    XCTAssertFalse(fixture.events.values.contains(.prepareReplacement))
    XCTAssertTrue(fixture.events.values.contains(.detach))
  }

  func testDisarmFailureNeverReplacesAndCleansPreparedUpdate() async throws {
    let fixture = try Fixture()
    fixture.helper.disarmError = StubError.failure

    await assertThrowsAsyncError(
      try await fixture.coordinator.install(fixture.release, installedApp: fixture.installedApp)
    )

    XCTAssertFalse(fixture.events.values.contains(.commitSwap))
    XCTAssertTrue(fixture.events.values.contains(.cleanupPreparedUpdate))
  }

  func testManualInstallReportsVerifiedDiskImageWithoutDisarming() async throws {
    let fixture = try Fixture()
    let manualImage = URL(fileURLWithPath: "/Users/test/Downloads/Lidless-v1.1.0.dmg")
    fixture.replacer.prepared = .manualInstall(diskImage: manualImage)

    try await fixture.coordinator.install(fixture.release, installedApp: fixture.installedApp)

    XCTAssertFalse(fixture.events.values.contains(.disarm))
    XCTAssertFalse(fixture.events.values.contains(.commitSwap))
    let phases = fixture.reporter.phases
    XCTAssertEqual(phases.last, .manualInstall(manualImage))
  }

  func testDetachFailureNeverDisarmsOrCommits() async throws {
    let fixture = try Fixture(detachError: StubError.failure)

    await assertThrowsAsyncError(
      try await fixture.coordinator.install(fixture.release, installedApp: fixture.installedApp)
    )

    XCTAssertFalse(fixture.events.values.contains(.disarm))
    XCTAssertFalse(fixture.events.values.contains(.commitSwap))
    XCTAssertTrue(fixture.events.values.contains(.cleanupPreparedUpdate))
  }

  func testChecksumFailureNeverMountsAndRemovesDownload() async throws {
    let fixture = try Fixture()
    fixture.hasher.hash = String(repeating: "f", count: 64)

    await assertThrowsAsyncError(
      try await fixture.coordinator.install(fixture.release, installedApp: fixture.installedApp)
    )

    XCTAssertFalse(fixture.events.values.contains(.mountReadOnly))
    XCTAssertEqual(fixture.downloader.removedFiles, [fixture.downloadedDiskImage])
  }

  func testMissingChecksumNeverDownloadsDiskImage() async throws {
    let fixture = try Fixture()
    fixture.downloader.manifest = "\(String(repeating: "a", count: 64))  Lidless.zip\n"

    await assertThrowsAsyncError(
      try await fixture.coordinator.install(fixture.release, installedApp: fixture.installedApp)
    )

    XCTAssertEqual(fixture.events.values, [.downloadManifest])
  }

  func testLaunchFailureRollsBackRestartsRestoredHelperAndCleans() async throws {
    let fixture = try Fixture()
    fixture.launcher.error = StubError.failure

    await assertThrowsAsyncError(
      try await fixture.coordinator.install(fixture.release, installedApp: fixture.installedApp)
    )

    XCTAssertEqual(
      Array(fixture.events.values.suffix(4)),
      [.launchNewInstance, .rollbackSwap, .restartHelper, .cleanupPreparedUpdate]
    )
  }

  func testRollbackStillCleansWhenRestoredHelperRestartFails() async throws {
    let fixture = try Fixture()
    fixture.launcher.error = StubError.failure
    fixture.helper.restartErrorOnCall = 2
    fixture.replacer.cleanupError = StubError.failure

    do {
      try await fixture.coordinator.install(fixture.release, installedApp: fixture.installedApp)
      XCTFail("Expected update failure")
    } catch let error as UpdateInstallError {
      XCTAssertEqual(error.primary, .launch)
      XCTAssertEqual(error.secondary, .helperRestart)
      XCTAssertEqual(error.tertiary, .cleanup)
    }

    XCTAssertEqual(
      Array(fixture.events.values.suffix(4)),
      [.launchNewInstance, .rollbackSwap, .restartHelper, .cleanupPreparedUpdate]
    )
  }

  func testCancellationStillDetachesAndRemovesDownload() async throws {
    let fixture = try Fixture()
    fixture.validator.error = CancellationError()

    await assertThrowsAsyncError(
      try await fixture.coordinator.install(fixture.release, installedApp: fixture.installedApp)
    )

    XCTAssertTrue(fixture.events.values.contains(.detach))
    XCTAssertEqual(fixture.downloader.removedFiles, [fixture.downloadedDiskImage])
  }
}

private enum UpdateTestEvent: Equatable {
  case downloadManifest
  case downloadDiskImage
  case verifyChecksum
  case mountReadOnly
  case validateIdentity(String)
  case prepareReplacement
  case detach
  case disarm
  case commitSwap
  case restartHelper
  case launchNewInstance
  case confirmNewProcess
  case rollbackSwap
  case cleanupPreparedUpdate
}

private final class UpdateEventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [UpdateTestEvent] = []

  var values: [UpdateTestEvent] {
    lock.withLock { events }
  }

  func append(_ event: UpdateTestEvent) {
    lock.withLock { events.append(event) }
  }
}

private final class StubDownloader: UpdateDownloading, @unchecked Sendable {
  let events: UpdateEventLog
  let diskImage: URL
  var manifest: String
  private(set) var removedFiles: [URL] = []

  init(events: UpdateEventLog, diskImage: URL, manifest: String) {
    self.events = events
    self.diskImage = diskImage
    self.manifest = manifest
  }

  func download(_ request: URLRequest, maximumBytes: Int64) async throws -> URL {
    events.append(.downloadDiskImage)
    return diskImage
  }

  func text(_ request: URLRequest, maximumBytes: Int) async throws -> String {
    events.append(.downloadManifest)
    return manifest
  }

  func removeDownloadedFile(_ url: URL) throws {
    removedFiles.append(url)
  }
}

private final class StubHasher: UpdateFileHashing, @unchecked Sendable {
  let events: UpdateEventLog
  var hash: String

  init(events: UpdateEventLog, hash: String) {
    self.events = events
    self.hash = hash
  }

  func sha256(of file: URL) throws -> String {
    events.append(.verifyChecksum)
    return hash
  }
}

private final class StubStager: UpdateStaging, @unchecked Sendable {
  let events: UpdateEventLog
  let session: MountedUpdateSession

  init(events: UpdateEventLog, session: MountedUpdateSession) {
    self.events = events
    self.session = session
  }

  func mount(diskImage: URL, version: SemanticVersion) throws -> MountedUpdateSession {
    events.append(.mountReadOnly)
    return session
  }
}

private final class StubValidator: StagedAppValidating, @unchecked Sendable {
  let events: UpdateEventLog
  var error: (any Error)?

  init(events: UpdateEventLog) {
    self.events = events
  }

  func validate(app: URL, expectedVersion: SemanticVersion) throws {
    events.append(.validateIdentity(expectedVersion.description))
    if let error { throw error }
  }
}

private final class StubReplacer: AppReplacing, @unchecked Sendable {
  let events: UpdateEventLog
  var prepared: PreparedInstall
  var prepareError: (any Error)?
  var cleanupError: (any Error)?

  init(events: UpdateEventLog, prepared: PreparedInstall) {
    self.events = events
    self.prepared = prepared
  }

  func prepare(
    mountedApp: URL,
    diskImage: URL,
    installedApp: URL,
    version: SemanticVersion,
    expectedDiskImageSHA256: String
  ) throws -> PreparedInstall {
    events.append(.prepareReplacement)
    if let prepareError { throw prepareError }
    return prepared
  }

  func commit(_ replacement: PreparedReplacement) throws -> ReplacementReceipt {
    events.append(.commitSwap)
    return ReplacementReceipt(
      installedApp: replacement.installedApp,
      oldAppSibling: replacement.stagedSibling,
      version: replacement.version
    )
  }

  func rollback(_ receipt: ReplacementReceipt) throws {
    events.append(.rollbackSwap)
  }

  func cleanup(_ prepared: PreparedInstall) throws {
    events.append(.cleanupPreparedUpdate)
    if let cleanupError { throw cleanupError }
  }
}

private final class StubUpdateHelper: UpdateHelperControlling, @unchecked Sendable {
  let events: UpdateEventLog
  var disarmError: (any Error)?
  var restartErrorOnCall: Int?
  private var restartCallCount = 0

  init(events: UpdateEventLog) {
    self.events = events
  }

  func disarmForUpdate() async throws {
    events.append(.disarm)
    if let disarmError { throw disarmError }
  }

  func restartAfterVerifiedUpdateSwap() async throws {
    events.append(.restartHelper)
    restartCallCount += 1
    if restartCallCount == restartErrorOnCall { throw StubError.failure }
  }
}

private final class StubLauncher: UpdatedAppLaunching, @unchecked Sendable {
  let events: UpdateEventLog
  var error: (any Error)?

  init(events: UpdateEventLog) {
    self.events = events
  }

  func launchNewInstance(
    app: URL,
    expectedVersion: SemanticVersion,
    oldAppSibling: URL
  ) async throws -> Int32 {
    events.append(.launchNewInstance)
    if let error { throw error }
    events.append(.confirmNewProcess)
    return 42
  }
}

@MainActor
private final class StubReporter: UpdateReporting {
  private(set) var phases: [UpdatePhase] = []

  func updatePhaseChanged(_ phase: UpdatePhase) {
    phases.append(phase)
  }
}

@MainActor
private struct Fixture {
  let events = UpdateEventLog()
  let release: ReleaseDescriptor
  let installedApp = URL(fileURLWithPath: "/Applications/Lidless.app")
  let downloadedDiskImage = URL(fileURLWithPath: "/private/tmp/Lidless.dmg")
  let downloader: StubDownloader
  let hasher: StubHasher
  let stager: StubStager
  let validator: StubValidator
  let replacer: StubReplacer
  let helper: StubUpdateHelper
  let launcher: StubLauncher
  let reporter: StubReporter
  let coordinator: UpdateCoordinator

  init(detachError: (any Error)? = nil) throws {
    let version = try SemanticVersion("1.1.0")
    let release = ReleaseDescriptor(version: version)
    let hash = String(repeating: "a", count: 64)
    let events = self.events
    let session = MountedUpdateSession(
      root: URL(fileURLWithPath: "/private/tmp/staged"),
      diskImage: downloadedDiskImage,
      app: URL(fileURLWithPath: "/private/tmp/staged/Lidless.app"),
      version: version
    ) {
      events.append(.detach)
      if let detachError { throw detachError }
    }
    let replacement = PreparedReplacement(
      installedApp: installedApp,
      stagedSibling: URL(fileURLWithPath: "/Applications/.Lidless.update-1.app"),
      version: version
    )
    downloader = StubDownloader(
      events: events,
      diskImage: downloadedDiskImage,
      manifest: "\(hash)  Lidless.dmg\n"
    )
    hasher = StubHasher(events: events, hash: hash)
    stager = StubStager(events: events, session: session)
    validator = StubValidator(events: events)
    replacer = StubReplacer(events: events, prepared: .replacement(replacement))
    helper = StubUpdateHelper(events: events)
    launcher = StubLauncher(events: events)
    reporter = StubReporter()
    self.release = release
    coordinator = UpdateCoordinator(
      downloader: downloader,
      hasher: hasher,
      stager: stager,
      validator: validator,
      replacer: replacer,
      helper: helper,
      launcher: launcher,
      reporter: reporter
    )
  }
}

private enum StubError: Error {
  case failure
}

@MainActor
private func assertThrowsAsyncError(
  _ expression: @autoclosure @MainActor () async throws -> some Any,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected error", file: file, line: line)
  } catch {}
}
