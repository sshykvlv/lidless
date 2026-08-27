import Darwin
import Foundation
import LidlessCore

enum UpdateStagerError: Error, Equatable {
  case temporaryRootCreationFailed
  case unsafeDiskImage
  case attachFailed(Int32)
  case malformedAttachOutput
  case mountInspectionFailed
  case unsafeBundleTree
  case bundleTooLarge
  case detachFailed(Int32)
  case cleanupFailed
}

final class HdiutilDiskImageAttacher: DiskImageAttaching, @unchecked Sendable {
  private static let executable = "/usr/bin/hdiutil"
  private static let commandTimeout: TimeInterval = 30

  private let runner: any CommandRunning
  private let fileManager: FileManager
  private let isMountedFileSystem: @Sendable (URL) -> Bool

  init(
    runner: any CommandRunning = UpdateProcessRunner(),
    fileManager: FileManager = .default,
    isMountedFileSystem: (@Sendable (URL) -> Bool)? = nil
  ) {
    self.runner = runner
    self.fileManager = fileManager
    self.isMountedFileSystem = isMountedFileSystem ?? Self.hasDistinctDevice(at:)
  }

  func attachReadOnly(image: URL, mountRoot: URL) throws -> MountedImageDescription {
    try validatePrivateMountPoint(mountRoot)
    let result = try runner.run(
      executable: Self.executable,
      arguments: [
        "attach", "-readonly", "-verify", "-nobrowse", "-noautoopen",
        "-owners", "off", "-mountpoint", mountRoot.path, "-plist", image.path,
      ],
      timeout: Self.commandTimeout
    )
    guard result.status == 0 else {
      if isMountedFileSystem(mountRoot) {
        do {
          try detachMountPointWithRetry(mountRoot)
        } catch {
          throw UpdateStagerError.cleanupFailed
        }
      }
      throw UpdateStagerError.attachFailed(result.status)
    }

    let mounted: HdiutilMountedEntity
    do {
      mounted = try HdiutilAttachOutput.parse(result.stdout)
    } catch {
      do {
        try detachMountPointWithRetry(mountRoot)
      } catch {
        throw UpdateStagerError.cleanupFailed
      }
      throw error
    }
    do {
      let expectedMountPoint = mountRoot.standardizedFileURL.resolvingSymlinksInPath()
      guard
        mounted.mountPoint.standardizedFileURL.resolvingSymlinksInPath()
          .path == expectedMountPoint.path
      else {
        throw MountedImagePolicyError.unexpectedMountPoint
      }
      var fileSystem = statfs()
      guard statfs(mounted.mountPoint.path, &fileSystem) == 0 else {
        throw UpdateStagerError.mountInspectionFailed
      }
      let isReadOnly = (UInt32(fileSystem.f_flags) & UInt32(MNT_RDONLY)) != 0
      let rootEntries = try fileManager.contentsOfDirectory(atPath: mounted.mountPoint.path)
        .sorted()
      return MountedImageDescription(
        device: mounted.device,
        mountPoint: mounted.mountPoint,
        isReadOnly: isReadOnly,
        rootEntries: rootEntries
      )
    } catch {
      do {
        try detach(device: mounted.device)
      } catch {
        Thread.sleep(forTimeInterval: 1)
        do {
          try detach(device: mounted.device)
        } catch {
          throw UpdateStagerError.cleanupFailed
        }
      }
      throw error
    }
  }

  func detach(device: String) throws {
    try MountedImagePolicy.validate(device: device)
    let result = try runner.run(
      executable: Self.executable,
      arguments: ["detach", device],
      timeout: Self.commandTimeout
    )
    guard result.status == 0 else {
      throw UpdateStagerError.detachFailed(result.status)
    }
  }

  private func detachMountPointWithRetry(_ mountPoint: URL) throws {
    do {
      try detachMountPoint(mountPoint)
    } catch {
      Thread.sleep(forTimeInterval: 1)
      try detachMountPoint(mountPoint)
    }
  }

  private func detachMountPoint(_ mountPoint: URL) throws {
    try validatePrivateMountPoint(mountPoint)
    let result = try runner.run(
      executable: Self.executable,
      arguments: ["detach", mountPoint.path],
      timeout: Self.commandTimeout
    )
    guard result.status == 0 else {
      throw UpdateStagerError.detachFailed(result.status)
    }
  }

  private func validatePrivateMountPoint(_ mountPoint: URL) throws {
    let temporaryRoot = fileManager.temporaryDirectory.standardizedFileURL
      .resolvingSymlinksInPath()
    let point = mountPoint.standardizedFileURL.resolvingSymlinksInPath()
    let privateRoot = point.deletingLastPathComponent()
    var metadata = stat()
    guard point.lastPathComponent == "mounts",
      privateRoot.lastPathComponent.hasPrefix("lv.ykv.lidless.update-"),
      privateRoot.deletingLastPathComponent().path == temporaryRoot.path,
      lstat(mountPoint.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR
    else {
      throw UpdateStagerError.temporaryRootCreationFailed
    }
  }

  private static func hasDistinctDevice(at mountPoint: URL) -> Bool {
    var mountMetadata = stat()
    var parentMetadata = stat()
    return stat(mountPoint.path, &mountMetadata) == 0
      && stat(mountPoint.deletingLastPathComponent().path, &parentMetadata) == 0
      && mountMetadata.st_dev != parentMetadata.st_dev
  }
}

final class UpdateStager: UpdateStaging, @unchecked Sendable {
  private static let maximumBundleBytes: Int64 = 128 * 1_024 * 1_024
  private static let maximumDiskImageBytes: Int64 = 32 * 1_024 * 1_024

  private let attacher: any DiskImageAttaching
  private let fileManager: FileManager

  init(
    attacher: any DiskImageAttaching = HdiutilDiskImageAttacher(),
    fileManager: FileManager = .default
  ) {
    self.attacher = attacher
    self.fileManager = fileManager
  }

  func mount(diskImage: URL, version: SemanticVersion) throws -> MountedUpdateSession {
    var diskImageMetadata = stat()
    guard lstat(diskImage.path, &diskImageMetadata) == 0,
      diskImageMetadata.st_mode & S_IFMT == S_IFREG,
      diskImageMetadata.st_size >= 0,
      diskImageMetadata.st_size <= Self.maximumDiskImageBytes
    else {
      throw UpdateStagerError.unsafeDiskImage
    }

    let temporaryRoot = fileManager.temporaryDirectory.standardizedFileURL
      .resolvingSymlinksInPath()
    let root = temporaryRoot.appendingPathComponent(
      "lv.ykv.lidless.update-\(UUID().uuidString)",
      isDirectory: true
    )
    let mountRoot = root.appendingPathComponent("mounts", isDirectory: true)

    do {
      try fileManager.createDirectory(
        at: mountRoot,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    } catch {
      throw UpdateStagerError.temporaryRootCreationFailed
    }

    let mount: MountedImageDescription
    do {
      mount = try attacher.attachReadOnly(image: diskImage, mountRoot: mountRoot)
    } catch {
      try? removePrivateRoot(root, below: temporaryRoot)
      throw error
    }

    do {
      let candidate = mount.mountPoint.appendingPathComponent("Lidless.app", isDirectory: true)
      let candidateKind = try kind(of: candidate)
      let resolvedCandidate = candidate.resolvingSymlinksInPath()
      try MountedImagePolicy.validate(
        mount: mount,
        expectedMountRoot: mountRoot,
        candidate: candidate,
        candidateKind: candidateKind,
        resolvedCandidate: resolvedCandidate
      )
      try validateBundleTree(candidate)

      return MountedUpdateSession(
        root: root,
        diskImage: diskImage,
        app: candidate,
        version: version
      ) { [attacher] in
        try Self.detachWithRetry(attacher: attacher, device: mount.device)
        try Self.removePrivateRoot(root, below: temporaryRoot, fileManager: .default)
      }
    } catch {
      do {
        try Self.detachWithRetry(attacher: attacher, device: mount.device)
        try removePrivateRoot(root, below: temporaryRoot)
      } catch {
        throw UpdateStagerError.cleanupFailed
      }
      throw error
    }
  }

  private func kind(of url: URL) throws -> MountedCandidateKind {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      throw UpdateStagerError.mountInspectionFailed
    }
    let fileType = metadata.st_mode & S_IFMT
    if fileType == S_IFLNK {
      return .symbolicLink
    }
    return fileType == S_IFDIR ? .directory : .other
  }

  private func validateBundleTree(_ app: URL) throws {
    let canonicalApp = app.standardizedFileURL.resolvingSymlinksInPath()
    let keys: [URLResourceKey] = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ]
    var inspectionError: (any Error)?
    guard
      let enumerator = fileManager.enumerator(
        at: app,
        includingPropertiesForKeys: keys,
        options: [],
        errorHandler: { _, error in
          inspectionError = error
          return false
        }
      )
    else {
      throw UpdateStagerError.mountInspectionFailed
    }

    var totalBytes: Int64 = 0
    while let item = enumerator.nextObject() as? URL {
      if inspectionError != nil {
        throw UpdateStagerError.mountInspectionFailed
      }
      let values = try item.resourceValues(forKeys: Set(keys))
      guard values.isSymbolicLink != true else {
        throw UpdateStagerError.unsafeBundleTree
      }
      let resolved = item.standardizedFileURL.resolvingSymlinksInPath()
      guard Self.isStrictChild(resolved, of: canonicalApp),
        values.isDirectory == true || values.isRegularFile == true
      else {
        throw UpdateStagerError.unsafeBundleTree
      }
      if values.isRegularFile == true {
        totalBytes += Int64(values.fileSize ?? 0)
        guard totalBytes <= Self.maximumBundleBytes else {
          throw UpdateStagerError.bundleTooLarge
        }
      }
    }
    if inspectionError != nil {
      throw UpdateStagerError.mountInspectionFailed
    }
  }

  private func removePrivateRoot(_ root: URL, below temporaryRoot: URL) throws {
    try Self.removePrivateRoot(root, below: temporaryRoot, fileManager: fileManager)
  }

  private static func detachWithRetry(attacher: any DiskImageAttaching, device: String) throws {
    do {
      try attacher.detach(device: device)
    } catch {
      Thread.sleep(forTimeInterval: 1)
      try attacher.detach(device: device)
    }
  }

  private static func removePrivateRoot(
    _ root: URL,
    below temporaryRoot: URL,
    fileManager: FileManager
  ) throws {
    let expectedParent = temporaryRoot.standardizedFileURL.resolvingSymlinksInPath()
    let standardizedRoot = root.standardizedFileURL
    guard standardizedRoot.deletingLastPathComponent().path == expectedParent.path,
      standardizedRoot.lastPathComponent.hasPrefix("lv.ykv.lidless.update-")
    else {
      throw UpdateStagerError.cleanupFailed
    }
    var metadata = stat()
    guard lstat(standardizedRoot.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      standardizedRoot.resolvingSymlinksInPath().path == standardizedRoot.path
    else {
      throw UpdateStagerError.cleanupFailed
    }
    try fileManager.removeItem(at: standardizedRoot)
  }

  private static func isStrictChild(_ candidate: URL, of parent: URL) -> Bool {
    let prefix = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
    return candidate.path.hasPrefix(prefix) && candidate.path != parent.path
  }
}
