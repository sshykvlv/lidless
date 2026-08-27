import Darwin
import Foundation
import XCTest

@testable import LidlessCore

final class UpdateTransactionJournalTests: XCTestCase {
  func testDurablyStoresLoadsAndRemovesExactTransaction() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let record = try fixture.record(phase: .prepared)

    try fixture.journal.store(record)

    XCTAssertEqual(try fixture.journal.load(installedApp: fixture.installedApp), record)
    var metadata = stat()
    XCTAssertEqual(lstat(fixture.journalURL.path, &metadata), 0)
    XCTAssertEqual(metadata.st_mode & 0o777, 0o600)

    try fixture.journal.remove(record)
    XCTAssertNil(try fixture.journal.load(installedApp: fixture.installedApp))
  }

  func testRejectsUnsafeSiblingAndPhaseRegression() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let unsafe = UpdateTransactionRecord(
      transactionID: UUID(),
      installedApp: fixture.installedApp,
      oldAppSibling: URL(fileURLWithPath: "/tmp/.Lidless.update-attacker.app"),
      previousVersion: try SemanticVersion("1.0.0"),
      targetVersion: try SemanticVersion("1.1.0"),
      phase: .prepared
    )
    XCTAssertThrowsError(try fixture.journal.store(unsafe))

    let prepared = try fixture.record(phase: .prepared)
    try fixture.journal.store(prepared)
    let committed = UpdateTransactionRecord(
      transactionID: prepared.transactionID,
      installedApp: prepared.installedApp,
      oldAppSibling: prepared.oldAppSibling,
      previousVersion: prepared.previousVersion,
      targetVersion: prepared.targetVersion,
      phase: .committed
    )
    try fixture.journal.store(committed)
    let regressed = UpdateTransactionRecord(
      transactionID: committed.transactionID,
      installedApp: committed.installedApp,
      oldAppSibling: committed.oldAppSibling,
      previousVersion: committed.previousVersion,
      targetVersion: committed.targetVersion,
      phase: .swapped
    )
    XCTAssertThrowsError(try fixture.journal.store(regressed))
  }
}

private final class Fixture {
  let root: URL
  let installedApp: URL
  let oldAppSibling: URL
  let journal = DurableUpdateTransactionJournal()

  var journalURL: URL {
    root.appendingPathComponent(".Lidless.update-transaction.json")
  }

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Lidless-UpdateJournalTests-\(UUID().uuidString)",
      isDirectory: true
    )
    installedApp = root.appendingPathComponent("Lidless.app", isDirectory: true)
    oldAppSibling = root.appendingPathComponent(
      ".Lidless.update-\(UUID().uuidString).app",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: installedApp, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: oldAppSibling, withIntermediateDirectories: true)
  }

  func record(phase: UpdateTransactionPhase) throws -> UpdateTransactionRecord {
    UpdateTransactionRecord(
      transactionID: UUID(),
      installedApp: installedApp,
      oldAppSibling: oldAppSibling,
      previousVersion: try SemanticVersion("1.0.0"),
      targetVersion: try SemanticVersion("1.1.0"),
      phase: phase
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
