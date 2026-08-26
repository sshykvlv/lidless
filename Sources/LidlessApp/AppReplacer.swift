import Darwin
import Foundation
import LidlessCore

enum AppReplacerError: Error, Equatable {
  case unsafeInstalledPath
  case noManualDestination
  case copyFailed(Int32)
  case checksumMismatch
  case unsafeReplacement
  case atomicSwapFailed(Int32)
}

final class AtomicAppReplacer: AppReplacing, @unchecked Sendable {
  private static let ditto = "/usr/bin/ditto"
  private static let copyTimeout: TimeInterval = 60

  private let validator: any StagedAppValidating
  private let hasher: any UpdateFileHashing
  private let runner: any CommandRunning
  private let fileManager: FileManager
  private let downloadsDirectory: URL

  init(
    validator: any StagedAppValidating,
    hasher: any UpdateFileHashing,
    runner: any CommandRunning = UpdateProcessRunner(),
    fileManager: FileManager = .default,
    downloadsDirectory: URL? = nil
  ) {
    self.validator = validator
    self.hasher = hasher
    self.runner = runner
    self.fileManager = fileManager
    self.downloadsDirectory =
      downloadsDirectory
      ?? fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Downloads", isDirectory: true)
  }

  func prepare(
    mountedApp: URL,
    diskImage: URL,
    installedApp: URL,
    version: SemanticVersion,
    expectedDiskImageSHA256: String
  ) throws -> PreparedInstall {
    let installed = installedApp.standardizedFileURL
    guard installed.lastPathComponent == "Lidless.app" else {
      throw AppReplacerError.unsafeInstalledPath
    }
    let parent = installed.deletingLastPathComponent()
    guard parent.path != "/", installed.resolvingSymlinksInPath().path == installed.path else {
      throw AppReplacerError.unsafeInstalledPath
    }

    if fileManager.isWritableFile(atPath: parent.path) {
      let staged = parent.appendingPathComponent(
        ".Lidless.update-\(UUID().uuidString).app",
        isDirectory: true
      )
      do {
        try copy(from: mountedApp, to: staged)
        try validator.validate(app: staged, expectedVersion: version)
        return .replacement(
          PreparedReplacement(installedApp: installed, stagedSibling: staged, version: version)
        )
      } catch {
        try? removeReplacement(at: staged, expectedParent: parent, expectedVersion: version)
        throw error
      }
    }

    let destination = try uniqueManualDestination(version: version)
    do {
      try copy(from: diskImage, to: destination)
      guard try hasher.sha256(of: destination) == expectedDiskImageSHA256 else {
        throw AppReplacerError.checksumMismatch
      }
      return .manualInstall(diskImage: destination)
    } catch {
      try? removeManualImage(at: destination)
      throw error
    }
  }

  func commit(_ replacement: PreparedReplacement) throws -> ReplacementReceipt {
    try validateReplacementPaths(replacement)
    try validator.validate(app: replacement.stagedSibling, expectedVersion: replacement.version)
    try swap(replacement.installedApp, replacement.stagedSibling)
    return ReplacementReceipt(
      installedApp: replacement.installedApp,
      oldAppSibling: replacement.stagedSibling,
      version: replacement.version
    )
  }

  func rollback(_ receipt: ReplacementReceipt) throws {
    let replacement = PreparedReplacement(
      installedApp: receipt.installedApp,
      stagedSibling: receipt.oldAppSibling,
      version: receipt.version
    )
    try validateReplacementPaths(replacement)
    try swap(receipt.installedApp, receipt.oldAppSibling)
  }

  func cleanup(_ prepared: PreparedInstall) throws {
    switch prepared {
    case .manualInstall:
      return
    case .replacement(let replacement):
      try removeReplacement(
        at: replacement.stagedSibling,
        expectedParent: replacement.installedApp.deletingLastPathComponent(),
        expectedVersion: replacement.version
      )
    }
  }

  func removeOldAppSibling(_ oldApp: URL, installedApp: URL) throws {
    let parent = installedApp.standardizedFileURL.deletingLastPathComponent()
    let bundle = Bundle(url: oldApp)
    guard
      let rawVersion = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    else {
      throw AppReplacerError.unsafeReplacement
    }
    let version = try SemanticVersion(rawVersion)
    try removeReplacement(at: oldApp, expectedParent: parent, expectedVersion: version)
  }

  private func copy(from source: URL, to destination: URL) throws {
    var metadata = stat()
    guard lstat(destination.path, &metadata) != 0 && errno == ENOENT else {
      throw AppReplacerError.unsafeReplacement
    }
    let result = try runner.run(
      executable: Self.ditto,
      arguments: [source.path, destination.path],
      timeout: Self.copyTimeout
    )
    guard result.status == 0 else {
      throw AppReplacerError.copyFailed(result.status)
    }
  }

  private func validateReplacementPaths(_ replacement: PreparedReplacement) throws {
    let installed = replacement.installedApp.standardizedFileURL
    let staged = replacement.stagedSibling.standardizedFileURL
    let parent = installed.deletingLastPathComponent()
    guard installed.lastPathComponent == "Lidless.app",
      staged.deletingLastPathComponent().path == parent.path,
      staged.lastPathComponent.hasPrefix(".Lidless.update-"),
      staged.lastPathComponent.hasSuffix(".app")
    else {
      throw AppReplacerError.unsafeReplacement
    }
    for url in [installed, staged] {
      var metadata = stat()
      guard lstat(url.path, &metadata) == 0,
        metadata.st_mode & S_IFMT == S_IFDIR,
        url.resolvingSymlinksInPath().path == url.path
      else {
        throw AppReplacerError.unsafeReplacement
      }
    }
  }

  private func swap(_ first: URL, _ second: URL) throws {
    let result = first.path.withCString { firstPath in
      second.path.withCString { secondPath in
        renameatx_np(AT_FDCWD, firstPath, AT_FDCWD, secondPath, UInt32(RENAME_SWAP))
      }
    }
    guard result == 0 else {
      throw AppReplacerError.atomicSwapFailed(errno)
    }
  }

  private func uniqueManualDestination(version: SemanticVersion) throws -> URL {
    for suffix in 0...999 {
      let suffixText = suffix == 0 ? "" : "-\(suffix)"
      let candidate = downloadsDirectory.appendingPathComponent(
        "Lidless-v\(version.description)\(suffixText).dmg"
      )
      var metadata = stat()
      if lstat(candidate.path, &metadata) != 0, errno == ENOENT {
        return candidate
      }
    }
    throw AppReplacerError.noManualDestination
  }

  private func removeReplacement(
    at url: URL,
    expectedParent: URL,
    expectedVersion: SemanticVersion
  ) throws {
    let replacement = url.standardizedFileURL
    guard replacement.deletingLastPathComponent().path == expectedParent.standardizedFileURL.path,
      replacement.lastPathComponent.hasPrefix(".Lidless.update-"),
      replacement.lastPathComponent.hasSuffix(".app")
    else {
      throw AppReplacerError.unsafeReplacement
    }
    var metadata = stat()
    guard lstat(replacement.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      replacement.resolvingSymlinksInPath().path == replacement.path
    else {
      throw AppReplacerError.unsafeReplacement
    }
    try validator.validate(app: replacement, expectedVersion: expectedVersion)
    try fileManager.removeItem(at: replacement)
  }

  private func removeManualImage(at url: URL) throws {
    let image = url.standardizedFileURL
    guard image.deletingLastPathComponent().path == downloadsDirectory.standardizedFileURL.path,
      image.lastPathComponent.hasPrefix("Lidless-v"),
      image.pathExtension == "dmg"
    else {
      throw AppReplacerError.unsafeReplacement
    }
    var metadata = stat()
    guard lstat(image.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      image.resolvingSymlinksInPath().path == image.path
    else {
      throw AppReplacerError.unsafeReplacement
    }
    try fileManager.removeItem(at: image)
  }
}
