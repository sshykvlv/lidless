import Foundation

public enum MountedCandidateKind: Equatable, Sendable {
  case directory
  case symbolicLink
  case other
}

public struct MountedImageDescription: Equatable, Sendable {
  public let device: String
  public let mountPoint: URL
  public let isReadOnly: Bool
  public let rootEntries: [String]

  public init(device: String, mountPoint: URL, isReadOnly: Bool, rootEntries: [String]) {
    self.device = device
    self.mountPoint = mountPoint
    self.isReadOnly = isReadOnly
    self.rootEntries = rootEntries
  }
}

public enum MountedImagePolicyError: Error, Equatable, Sendable {
  case unsafeDevice
  case writableVolume
  case unexpectedMountPoint
  case unexpectedRootEntries
  case unexpectedCandidate
  case unsafeCandidate
}

public enum MountedImagePolicy {
  public static func validate(
    mount: MountedImageDescription,
    expectedMountRoot: URL,
    candidate: URL,
    candidateKind: MountedCandidateKind,
    resolvedCandidate: URL
  ) throws {
    try validate(device: mount.device)
    guard mount.isReadOnly else {
      throw MountedImagePolicyError.writableVolume
    }

    let root = canonical(expectedMountRoot)
    let mountedVolume = canonical(mount.mountPoint)
    guard mountedVolume.deletingLastPathComponent().path == root.path else {
      throw MountedImagePolicyError.unexpectedMountPoint
    }
    guard mount.rootEntries == ["Lidless.app"] else {
      throw MountedImagePolicyError.unexpectedRootEntries
    }

    let expectedCandidate = canonical(
      mountedVolume.appendingPathComponent("Lidless.app", isDirectory: true)
    )
    guard canonical(candidate).path == expectedCandidate.path else {
      throw MountedImagePolicyError.unexpectedCandidate
    }
    guard candidateKind == .directory,
      canonical(resolvedCandidate).path == expectedCandidate.path,
      isStrictChild(expectedCandidate, of: mountedVolume)
    else {
      throw MountedImagePolicyError.unsafeCandidate
    }
  }

  public static func validate(device: String) throws {
    guard isSafeDevice(device) else {
      throw MountedImagePolicyError.unsafeDevice
    }
  }

  private static func canonical(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }

  private static func isStrictChild(_ candidate: URL, of parent: URL) -> Bool {
    let parentPath = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
    return candidate.path.hasPrefix(parentPath) && candidate.path != parent.path
  }

  private static func isSafeDevice(_ value: String) -> Bool {
    let prefix = "/dev/disk"
    guard value.hasPrefix(prefix) else {
      return false
    }
    let suffix = value.dropFirst(prefix.count)
    let components = suffix.split(separator: "s", omittingEmptySubsequences: false)
    return !components.isEmpty
      && components.allSatisfy { component in
        !component.isEmpty && component.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
      }
  }
}
