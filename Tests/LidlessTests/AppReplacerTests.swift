import Foundation
import XCTest

@testable import LidlessCore

final class AppReplacerTests: XCTestCase {
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

    try fixture.replacer.rollback(receipt)
    XCTAssertEqual(try fixture.marker(in: fixture.installedApp), "old")
    XCTAssertEqual(try fixture.marker(in: receipt.oldAppSibling), "new")

    try fixture.replacer.cleanup(.replacement(prepared))
    XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.stagedSibling.path))
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
  func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
    XCTAssertEqual(executable, "/usr/bin/ditto")
    XCTAssertEqual(arguments.count, 2)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: arguments[0], isDirectory: true),
      to: URL(fileURLWithPath: arguments[1], isDirectory: true)
    )
    return CommandResult(status: 0, stdout: "", stderr: "")
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
  let validator = RecordingValidator()
  let replacer: AtomicAppReplacer
  let version: SemanticVersion

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Lidless-AppReplacerTests-\(UUID().uuidString)", isDirectory: true)
    installedApp = root.appendingPathComponent("Lidless.app", isDirectory: true)
    mountedApp = root.appendingPathComponent("Mounted/Lidless.app", isDirectory: true)
    diskImage = root.appendingPathComponent("Lidless.dmg")
    version = try SemanticVersion("1.1.0")
    try FileManager.default.createDirectory(at: installedApp, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: mountedApp, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: installedApp.appendingPathComponent("marker"))
    try Data("new".utf8).write(to: mountedApp.appendingPathComponent("marker"))
    try Data("image".utf8).write(to: diskImage)
    replacer = AtomicAppReplacer(
      validator: validator,
      hasher: FixedHasher(),
      runner: FixtureCommandRunner(),
      downloadsDirectory: root.appendingPathComponent("Downloads", isDirectory: true)
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
}
