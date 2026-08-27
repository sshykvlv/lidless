import Foundation
import XCTest

@testable import LidlessCore

final class UpdateStagerCleanupTests: XCTestCase {
  func testMalformedSuccessfulAttachDetachesByExactPrivateMountPoint() throws {
    let runner = AttachCleanupRunner(attachStatus: 0, attachOutput: "malformed plist")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "lv.ykv.lidless.update-\(UUID().uuidString)", isDirectory: true)
    let mountPoint = root.appendingPathComponent("mounts", isDirectory: true)
    try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let attacher = HdiutilDiskImageAttacher(runner: runner)
    XCTAssertThrowsError(
      try attacher.attachReadOnly(
        image: root.appendingPathComponent("Lidless.dmg"),
        mountRoot: mountPoint
      )
    )

    XCTAssertEqual(runner.calls.count, 2)
    XCTAssertTrue(runner.calls[0].contains("-mountpoint"))
    XCTAssertFalse(runner.calls[0].contains("-mountroot"))
    XCTAssertEqual(runner.calls[1], ["detach", mountPoint.path])
  }

  func testFailedAttachDetachesWhenExactPrivateMountPointWasPartiallyMounted() throws {
    let runner = AttachCleanupRunner(attachStatus: 1, attachOutput: "attach failed")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "lv.ykv.lidless.update-\(UUID().uuidString)", isDirectory: true)
    let mountPoint = root.appendingPathComponent("mounts", isDirectory: true)
    try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let attacher = HdiutilDiskImageAttacher(
      runner: runner,
      isMountedFileSystem: { $0 == mountPoint }
    )
    XCTAssertThrowsError(
      try attacher.attachReadOnly(
        image: root.appendingPathComponent("Lidless.dmg"),
        mountRoot: mountPoint
      )
    ) { error in
      XCTAssertEqual(error as? UpdateStagerError, .attachFailed(1))
    }

    XCTAssertEqual(runner.calls.last, ["detach", mountPoint.path])
  }
}

private final class AttachCleanupRunner: CommandRunning {
  private(set) var calls: [[String]] = []
  private let attachStatus: Int32
  private let attachOutput: String

  init(attachStatus: Int32, attachOutput: String) {
    self.attachStatus = attachStatus
    self.attachOutput = attachOutput
  }

  func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
    calls.append(arguments)
    if arguments.first == "attach" {
      return CommandResult(status: attachStatus, stdout: attachOutput, stderr: "")
    }
    return CommandResult(status: 0, stdout: "", stderr: "")
  }
}
