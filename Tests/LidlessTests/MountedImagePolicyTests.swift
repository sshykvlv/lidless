import Foundation
import XCTest

@testable import LidlessCore

final class MountedImagePolicyTests: XCTestCase {
  private let mountRoot = URL(fileURLWithPath: "/private/tmp/lidless-mounts")

  func testAcceptsOneReadOnlyRootLidlessBundle() throws {
    let mountedVolume = mountRoot
    let candidate = mountedVolume.appendingPathComponent("Lidless.app", isDirectory: true)
    let mount = MountedImageDescription(
      device: "/dev/disk42s1",
      mountPoint: mountedVolume,
      isReadOnly: true,
      rootEntries: ["Lidless.app"]
    )

    XCTAssertNoThrow(
      try MountedImagePolicy.validate(
        mount: mount,
        expectedMountRoot: mountRoot,
        candidate: candidate,
        candidateKind: .directory,
        resolvedCandidate: candidate
      )
    )
  }

  func testRejectsWritableWrongMountpointExtraRootSymlinkAndEscape() throws {
    let mountedVolume = mountRoot
    let candidate = mountedVolume.appendingPathComponent("Lidless.app", isDirectory: true)
    let outside = URL(fileURLWithPath: "/private/tmp/outside", isDirectory: true)
    let unexpectedChild = mountRoot.appendingPathComponent("Lidless", isDirectory: true)

    XCTAssertThrowsError(
      try validate(
        mount: makeMount(mountPoint: mountedVolume, isReadOnly: false),
        candidate: candidate
      )
    )
    XCTAssertThrowsError(
      try validate(
        mount: makeMount(mountPoint: outside),
        candidate: outside.appendingPathComponent("Lidless.app", isDirectory: true)
      )
    )
    XCTAssertThrowsError(
      try validate(
        mount: makeMount(mountPoint: unexpectedChild),
        candidate: unexpectedChild.appendingPathComponent("Lidless.app", isDirectory: true)
      )
    )
    XCTAssertThrowsError(
      try validate(
        mount: makeMount(mountPoint: mountedVolume, rootEntries: ["Lidless.app", "payload.sh"]),
        candidate: candidate
      )
    )
    XCTAssertThrowsError(
      try validate(
        mount: makeMount(mountPoint: mountedVolume),
        candidate: candidate,
        candidateKind: .symbolicLink
      )
    )
    XCTAssertThrowsError(
      try validate(
        mount: makeMount(mountPoint: mountedVolume),
        candidate: candidate,
        resolvedCandidate: outside.appendingPathComponent("Lidless.app", isDirectory: true)
      )
    )
  }

  func testRejectsWrongCandidateAndUnsafeDevice() throws {
    let mountedVolume = mountRoot
    let candidate = mountedVolume.appendingPathComponent("Other.app", isDirectory: true)

    XCTAssertThrowsError(
      try validate(
        mount: makeMount(mountPoint: mountedVolume),
        candidate: candidate
      )
    )
    XCTAssertThrowsError(
      try validate(
        mount: makeMount(mountPoint: mountedVolume, device: "/tmp/not-a-device"),
        candidate: mountedVolume.appendingPathComponent("Lidless.app", isDirectory: true)
      )
    )
  }

  func testMountedSessionDetachesExactlyOnce() throws {
    let counter = LockedCounter()
    let version = try SemanticVersion("1.1.0")
    let session = MountedUpdateSession(
      root: mountRoot,
      diskImage: mountRoot.appendingPathComponent("Lidless.dmg"),
      app: mountRoot.appendingPathComponent("Lidless/Lidless.app"),
      version: version
    ) {
      counter.increment()
    }

    try session.detach()
    try session.detach()

    XCTAssertEqual(counter.value, 1)
  }

  func testParsesExactlyOneMountedHdiutilEntity() throws {
    let output = try attachPlist(
      entities: [
        ["dev-entry": "/dev/disk42"],
        ["dev-entry": "/dev/disk42s1", "mount-point": "/private/tmp/Lidless"],
      ]
    )

    let entity = try HdiutilAttachOutput.parse(output)

    XCTAssertEqual(entity.device, "/dev/disk42s1")
    XCTAssertEqual(entity.mountPoint.path, "/private/tmp/Lidless")
  }

  func testRejectsAmbiguousMalformedAndOversizedHdiutilOutput() throws {
    let ambiguous = try attachPlist(
      entities: [
        ["dev-entry": "/dev/disk42s1", "mount-point": "/private/tmp/One"],
        ["dev-entry": "/dev/disk42s2", "mount-point": "/private/tmp/Two"],
      ]
    )
    XCTAssertThrowsError(try HdiutilAttachOutput.parse(ambiguous))
    XCTAssertThrowsError(try HdiutilAttachOutput.parse("not a plist"))
    XCTAssertThrowsError(
      try HdiutilAttachOutput.parse(String(repeating: "x", count: 65_537))
    )
  }

  private func makeMount(
    mountPoint: URL,
    isReadOnly: Bool = true,
    rootEntries: [String] = ["Lidless.app"],
    device: String = "/dev/disk42s1"
  ) -> MountedImageDescription {
    MountedImageDescription(
      device: device,
      mountPoint: mountPoint,
      isReadOnly: isReadOnly,
      rootEntries: rootEntries
    )
  }

  private func validate(
    mount: MountedImageDescription,
    candidate: URL,
    candidateKind: MountedCandidateKind = .directory,
    resolvedCandidate: URL? = nil
  ) throws {
    try MountedImagePolicy.validate(
      mount: mount,
      expectedMountRoot: mountRoot,
      candidate: candidate,
      candidateKind: candidateKind,
      resolvedCandidate: resolvedCandidate ?? candidate
    )
  }

  private func attachPlist(entities: [[String: String]]) throws -> String {
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["system-entities": entities],
      format: .xml,
      options: 0
    )
    return String(decoding: data, as: UTF8.self)
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.withLock { count }
  }

  func increment() {
    lock.withLock { count += 1 }
  }
}
