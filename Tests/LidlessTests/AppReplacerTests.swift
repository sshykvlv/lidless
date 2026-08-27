import Foundation
import XCTest

@testable import LidlessCore

final class AppReplacerTests: XCTestCase {
  func testFailedPartialCopyRemovesOnlyOwnedStagingDirectory() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    fixture.runner.copyStatus = 1

    XCTAssertThrowsError(try fixture.prepare())

    let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
    XCTAssertFalse(entries.contains { $0.hasPrefix(".Lidless.update-") })
    XCTAssertEqual(try fixture.marker(in: fixture.installedApp), "old")
  }

  func testCommitRevalidatesSiblingImmediatelyBeforeSwap() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let prepared = try fixture.prepare()
    fixture.validator.error = TestError.rejected

    XCTAssertThrowsError(try fixture.replacer.commit(prepared))

    XCTAssertEqual(try fixture.marker(in: fixture.installedApp), "old")
    XCTAssertEqual(try fixture.marker(in: prepared.stagedSibling), "new")
    XCTAssertEqual(fixture.validator.validatedURLs.last, prepared.stagedSibling)
  }

  func testAtomicSwapRollbackAndCleanupRestoreOriginalApp() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let prepared = try fixture.prepare()

    let receipt = try fixture.replacer.commit(prepared)
    XCTAssertEqual(try fixture.marker(in: fixture.installedApp), "new")
    XCTAssertEqual(try fixture.marker(in: receipt.oldAppSibling), "old")
    XCTAssertEqual(
      try fixture.journal.load(installedApp: fixture.installedApp)?.phase,
      .swapped
    )

    try fixture.replacer.rollback(receipt)
    XCTAssertEqual(try fixture.marker(in: fixture.installedApp), "old")
    XCTAssertEqual(try fixture.marker(in: receipt.oldAppSibling), "new")

    try fixture.replacer.cleanup(.replacement(prepared))
    XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.stagedSibling.path))
    XCTAssertNil(try fixture.journal.load(installedApp: fixture.installedApp))
  }

  func testCommittedUpdateRemovesOnlyValidatedOldSiblingAndJournal() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let receipt = try fixture.replacer.commit(fixture.prepare())

    try fixture.replacer.markUpdateCommitted(
      installedApp: receipt.installedApp,
      oldAppSibling: receipt.oldAppSibling
    )
    XCTAssertEqual(
      try fixture.journal.load(installedApp: fixture.installedApp)?.phase,
      .committed
    )

    try fixture.replacer.removeOldAppSibling(
      receipt.oldAppSibling,
      installedApp: receipt.installedApp
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.oldAppSibling.path))
    XCTAssertNil(try fixture.journal.load(installedApp: fixture.installedApp))
    XCTAssertEqual(try fixture.marker(in: fixture.installedApp), "new")
  }

  func testStartupRecoveryRollsBackUncommittedSwap() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    _ = try fixture.replacer.commit(fixture.prepare())

    XCTAssertEqual(
      try fixture.replacer.recoverPendingUpdate(installedApp: fixture.installedApp),
      .rolledBack
    )

    XCTAssertEqual(try fixture.marker(in: fixture.installedApp), "old")
    XCTAssertNil(try fixture.journal.load(installedApp: fixture.installedApp))
  }

  func testFailureCleanupRemovesOnlyExactOwnedManualDiskImage() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let image = fixture.downloadsDirectory.appendingPathComponent("Lidless-v1.1.0.dmg")
    try Data("verified-image".utf8).write(to: image)

    try fixture.replacer.cleanup(.manualInstall(diskImage: image))

    XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
  }
}

private enum TestError: Error {
  case rejected
}

private final class RecordingValidator: StagedAppValidating, @unchecked Sendable {
  var error: (any Error)?
  private(set) var validatedURLs: [URL] = []

  func validate(app: URL, expectedVersion: SemanticVersion) throws {
    validatedURLs.append(app)
    if let error { throw error }
  }
}

private final class FixtureCommandRunner: CommandRunning {
  var copyStatus: Int32 = 0

  func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
    XCTAssertEqual(executable, "/usr/bin/ditto")
    XCTAssertEqual(arguments.count, 2)
    let source = URL(fileURLWithPath: arguments[0], isDirectory: true)
    let destination = URL(fileURLWithPath: arguments[1], isDirectory: true)
    for entry in try FileManager.default.contentsOfDirectory(
      at: source,
      includingPropertiesForKeys: nil
    ) {
      try FileManager.default.copyItem(
        at: entry,
        to: destination.appendingPathComponent(entry.lastPathComponent)
      )
    }
    return CommandResult(status: copyStatus, stdout: "", stderr: "")
  }
}

private final class FixedHasher: UpdateFileHashing, @unchecked Sendable {
  func sha256(of file: URL) throws -> String {
    String(repeating: "a", count: 64)
  }
}

private final class Fixture {
  let root: URL
  let installedApp: URL
  let mountedApp: URL
  let diskImage: URL
  let downloadsDirectory: URL
  let validator = RecordingValidator()
  let journal = DurableUpdateTransactionJournal()
  let runner = FixtureCommandRunner()
  let replacer: AtomicAppReplacer
  let version: SemanticVersion

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Lidless-AppReplacerTests-\(UUID().uuidString)", isDirectory: true)
    installedApp = root.appendingPathComponent("Lidless.app", isDirectory: true)
    mountedApp = root.appendingPathComponent("Mounted/Lidless.app", isDirectory: true)
    diskImage = root.appendingPathComponent("Lidless.dmg")
    downloadsDirectory = root.appendingPathComponent("Downloads", isDirectory: true)
    version = try SemanticVersion("1.1.0")
    try Self.makeBundle(at: installedApp, version: "1.0.0", marker: "old")
    try Self.makeBundle(at: mountedApp, version: "1.1.0", marker: "new")
    try Data("image".utf8).write(to: diskImage)
    try FileManager.default.createDirectory(
      at: downloadsDirectory,
      withIntermediateDirectories: false
    )
    replacer = AtomicAppReplacer(
      validator: validator,
      hasher: FixedHasher(),
      runner: runner,
      journal: journal,
      downloadsDirectory: downloadsDirectory
    )
  }

  func prepare() throws -> PreparedReplacement {
    let prepared = try replacer.prepare(
      mountedApp: mountedApp,
      diskImage: diskImage,
      installedApp: installedApp,
      version: version,
      expectedDiskImageSHA256: String(repeating: "a", count: 64)
    )
    guard case .replacement(let replacement) = prepared else {
      throw TestError.rejected
    }
    return replacement
  }

  func marker(in app: URL) throws -> String {
    try String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  private static func makeBundle(at url: URL, version: String, marker: String) throws {
    let contents = url.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist: [String: Any] = [
      "CFBundleIdentifier": "lv.ykv.lidless",
      "CFBundleName": "Lidless",
      "CFBundlePackageType": "APPL",
      "CFBundleShortVersionString": version,
      "CFBundleVersion": version,
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .binary,
      options: 0
    )
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    try Data(marker.utf8).write(to: url.appendingPathComponent("marker"))
  }
}
