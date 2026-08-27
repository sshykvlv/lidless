import Foundation
import XCTest

@testable import LidlessCore

final class LegacyGrantMigratorTests: XCTestCase {
  private var filesystem: FakeLegacyGrantFileSystem!
  private var migrator: LegacyGrantMigrator!

  override func setUp() {
    super.setUp()
    filesystem = FakeLegacyGrantFileSystem()
    migrator = LegacyGrantMigrator(filesystem: filesystem)
  }

  func testDeletesOnlyKnownHistoricalRulesAtKnownPaths() throws {
    let rules = [
      "sashayakovlev ALL=(ALL) NOPASSWD: /usr/bin/pmset\n",
      "sashayakovlev ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n",
    ]

    for path in LegacyGrantMigrator.knownPaths {
      for rule in rules {
        filesystem.removed.removeAll()
        let file = candidate(path: path, contents: rule)

        XCTAssertEqual(try migrator.removeIfRecognized(file), .removed)
        XCTAssertEqual(filesystem.removed, [path])
      }
    }
  }

  func testNeverDeletesEditedSymlinkWrongOwnerOrUnknownPath() throws {
    let edited = candidate(
      path: "/etc/sudoers.d/keepawake",
      contents: "sashayakovlev ALL=(ALL) NOPASSWD: /usr/bin/pmset, /bin/sh\n"
    )
    let symlink = candidate(
      path: "/etc/sudoers.d/keepawake",
      kind: .symbolicLink
    )
    let nonRoot = candidate(
      path: "/etc/sudoers.d/keepawake",
      ownerUID: 501
    )
    let otherPath = candidate(path: "/tmp/keepawake")

    XCTAssertEqual(try migrator.removeIfRecognized(edited), .manualCleanupRequired)
    XCTAssertEqual(try migrator.removeIfRecognized(symlink), .manualCleanupRequired)
    XCTAssertEqual(try migrator.removeIfRecognized(nonRoot), .manualCleanupRequired)
    XCTAssertEqual(try migrator.removeIfRecognized(otherPath), .notEligible)
    XCTAssertTrue(filesystem.removed.isEmpty)
  }

  func testRejectsWritableExecutableAndOversizedFiles() throws {
    for mode: UInt16 in [0o640, 0o442, 0o550] {
      XCTAssertEqual(
        try migrator.removeIfRecognized(candidate(path: knownPath, mode: mode)),
        .manualCleanupRequired
      )
    }
    let oversized = LegacyGrantFile(
      path: knownPath,
      kind: .regular,
      ownerUID: 0,
      mode: 0o440,
      byteCount: 513,
      contents: Data(repeating: 0x41, count: 513)
    )
    XCTAssertEqual(try migrator.removeIfRecognized(oversized), .manualCleanupRequired)
    XCTAssertTrue(filesystem.removed.isEmpty)
  }

  func testRejectsInvalidUsernameAndExtraLines() throws {
    let invalidUsername = candidate(
      path: knownPath,
      contents: "bad/user ALL=(ALL) NOPASSWD: /usr/bin/pmset\n"
    )
    let extraLine = candidate(
      path: knownPath,
      contents: "sasha ALL=(ALL) NOPASSWD: /usr/bin/pmset\nsasha ALL=(ALL) NOPASSWD: /bin/sh\n"
    )

    XCTAssertEqual(try migrator.removeIfRecognized(invalidUsername), .manualCleanupRequired)
    XCTAssertEqual(try migrator.removeIfRecognized(extraLine), .manualCleanupRequired)
    XCTAssertTrue(filesystem.removed.isEmpty)
  }

  func testAggregateChecksOnlyFixedPathsAndReportsManualCleanup() throws {
    filesystem.files[LegacyGrantMigrator.knownPaths[0]] = candidate(
      path: LegacyGrantMigrator.knownPaths[0]
    )
    filesystem.files[LegacyGrantMigrator.knownPaths[1]] = candidate(
      path: LegacyGrantMigrator.knownPaths[1],
      contents: "edited"
    )

    XCTAssertEqual(try migrator.removeRecognizedGrants(), .manualCleanupRequired)
    XCTAssertEqual(filesystem.inspected, LegacyGrantMigrator.knownPaths)
    XCTAssertEqual(filesystem.removed, [LegacyGrantMigrator.knownPaths[0]])
  }

  func testAggregateReportsNotFoundAndRemoved() throws {
    XCTAssertEqual(try migrator.removeRecognizedGrants(), .notFound)

    filesystem.files[knownPath] = candidate(path: knownPath)
    XCTAssertEqual(try migrator.removeRecognizedGrants(), .removed)
  }

  func testUnlinkFailureDoesNotReportSuccess() {
    filesystem.unlinkError = TestLegacyError.unlinkFailed

    XCTAssertThrowsError(try migrator.removeIfRecognized(candidate(path: knownPath)))
  }

  private var knownPath: String { LegacyGrantMigrator.knownPaths[0] }

  private func candidate(
    path: String,
    kind: LegacyGrantFileKind = .regular,
    ownerUID: UInt32 = 0,
    mode: UInt16 = 0o440,
    contents: String = "sashayakovlev ALL=(ALL) NOPASSWD: /usr/bin/pmset\n"
  ) -> LegacyGrantFile {
    let data = Data(contents.utf8)
    return LegacyGrantFile(
      path: path,
      kind: kind,
      ownerUID: ownerUID,
      mode: mode,
      byteCount: data.count,
      contents: data
    )
  }
}

private enum TestLegacyError: Error {
  case unlinkFailed
}

private final class FakeLegacyGrantFileSystem: LegacyGrantFileSystem {
  var files: [String: LegacyGrantFile] = [:]
  var inspected: [String] = []
  var removed: [String] = []
  var unlinkError: Error?

  func inspect(path: String, maximumBytes: Int) throws -> LegacyGrantFile? {
    inspected.append(path)
    return files[path]
  }

  func unlink(path: String) throws {
    if let unlinkError {
      throw unlinkError
    }
    removed.append(path)
    files[path] = nil
  }
}
