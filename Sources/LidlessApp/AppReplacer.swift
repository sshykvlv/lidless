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
  case updateTransactionInvalid
}

enum PendingUpdateRecoveryResult: Equatable {
  case none
  case rolledBack
  case finalized
}

final class AtomicAppReplacer: AppReplacing, @unchecked Sendable {
  private static let ditto = "/usr/bin/ditto"
  private static let copyTimeout: TimeInterval = 60

  private let validator: any StagedAppValidating
  private let hasher: any UpdateFileHashing
  private let runner: any CommandRunning
  private let fileManager: FileManager
  private let journal: DurableUpdateTransactionJournal
  private let downloadsDirectory: URL

  init(
    validator: any StagedAppValidating,
    hasher: any UpdateFileHashing,
    runner: any CommandRunning = UpdateProcessRunner(),
    fileManager: FileManager = .default,
    journal: DurableUpdateTransactionJournal = DurableUpdateTransactionJournal(),
    downloadsDirectory: URL? = nil
  ) {
    self.validator = validator
    self.hasher = hasher
    self.runner = runner
    self.fileManager = fileManager
    self.journal = journal
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
      let previousVersion = try appVersion(at: installed)
      guard version > previousVersion else {
        throw AppReplacerError.updateTransactionInvalid
      }
      let staged = parent.appendingPathComponent(
        ".Lidless.update-\(UUID().uuidString).app",
        isDirectory: true
      )
      let stagedInode = try createOwnedStagingDirectory(at: staged)
      do {
        try runCopy(from: mountedApp, to: staged)
        try validator.validate(app: staged, expectedVersion: version)
        return .replacement(
          PreparedReplacement(
            installedApp: installed,
            stagedSibling: staged,
            stagedInode: stagedInode,
            previousVersion: previousVersion,
            version: version
          )
        )
      } catch {
        try? removeOwnedStagingDirectory(
          at: staged,
          expectedParent: parent,
          expectedInode: stagedInode
        )
        throw error
      }
    }

    let destination = try uniqueManualDestination(version: version)
    do {
      try copyToNewPath(from: diskImage, to: destination)
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
    try validateReplacementPaths(replacement, expectedStagedInode: replacement.stagedInode)
    try validator.validate(app: replacement.stagedSibling, expectedVersion: replacement.version)
    try validator.validate(
      app: replacement.installedApp,
      expectedVersion: replacement.previousVersion
    )
    let preparedRecord = UpdateTransactionRecord(
      transactionID: UUID(),
      installedApp: replacement.installedApp,
      oldAppSibling: replacement.stagedSibling,
      previousVersion: replacement.previousVersion,
      targetVersion: replacement.version,
      phase: .prepared
    )
    try journal.store(preparedRecord)
    do {
      try swap(replacement.installedApp, replacement.stagedSibling)
    } catch {
      try? journal.remove(preparedRecord)
      throw error
    }
    let swappedRecord = record(preparedRecord, phase: .swapped)
    do {
      try journal.store(swappedRecord)
    } catch {
      if (try? swap(replacement.installedApp, replacement.stagedSibling)) != nil {
        try? journal.remove(preparedRecord)
      }
      throw error
    }
    return ReplacementReceipt(
      installedApp: replacement.installedApp,
      oldAppSibling: replacement.stagedSibling,
      previousVersion: replacement.previousVersion,
      version: replacement.version,
      transactionID: preparedRecord.transactionID,
      targetInode: replacement.stagedInode
    )
  }

  func rollback(_ receipt: ReplacementReceipt) throws {
    let replacement = PreparedReplacement(
      installedApp: receipt.installedApp,
      stagedSibling: receipt.oldAppSibling,
      stagedInode: receipt.targetInode,
      previousVersion: receipt.previousVersion,
      version: receipt.version
    )
    try validateReplacementPaths(replacement, expectedStagedInode: nil)
    var installedMetadata = stat()
    guard lstat(receipt.installedApp.path, &installedMetadata) == 0,
      UInt64(installedMetadata.st_ino) == receipt.targetInode
    else {
      throw AppReplacerError.updateTransactionInvalid
    }
    guard let transaction = try journal.load(installedApp: receipt.installedApp),
      transaction.transactionID == receipt.transactionID,
      transaction.phase == .swapped
    else {
      throw AppReplacerError.updateTransactionInvalid
    }
    try swap(receipt.installedApp, receipt.oldAppSibling)
    try journal.remove(transaction)
  }

  func cleanup(_ prepared: PreparedInstall) throws {
    switch prepared {
    case .manualInstall(let diskImage):
      try removeManualImage(at: diskImage)
    case .replacement(let replacement):
      guard try journal.load(installedApp: replacement.installedApp) == nil else {
        throw AppReplacerError.updateTransactionInvalid
      }
      try removeReplacement(
        at: replacement.stagedSibling,
        expectedParent: replacement.installedApp.deletingLastPathComponent(),
        expectedVersion: replacement.version,
        expectedInode: replacement.stagedInode
      )
    }
  }

  func removeOldAppSibling(_ oldApp: URL, installedApp: URL) throws {
    guard let transaction = try journal.load(installedApp: installedApp),
      transaction.phase == .committed,
      transaction.oldAppSibling.path == oldApp.standardizedFileURL.path
    else {
      throw AppReplacerError.updateTransactionInvalid
    }
    try validator.validate(app: installedApp, expectedVersion: transaction.targetVersion)
    try removeReplacement(
      at: oldApp,
      expectedParent: installedApp.standardizedFileURL.deletingLastPathComponent(),
      expectedVersion: transaction.previousVersion
    )
    try journal.remove(transaction)
  }

  func markUpdateCommitted(installedApp: URL, oldAppSibling: URL) throws {
    guard let transaction = try journal.load(installedApp: installedApp),
      transaction.phase == .swapped,
      transaction.oldAppSibling.path == oldAppSibling.standardizedFileURL.path
    else {
      throw AppReplacerError.updateTransactionInvalid
    }
    try validator.validate(app: installedApp, expectedVersion: transaction.targetVersion)
    try validator.validate(app: oldAppSibling, expectedVersion: transaction.previousVersion)
    try journal.store(record(transaction, phase: .committed))
  }

  func recoverPendingUpdate(installedApp: URL) throws -> PendingUpdateRecoveryResult {
    guard let transaction = try journal.load(installedApp: installedApp) else {
      return .none
    }
    let installed = installedApp.standardizedFileURL
    guard transaction.installedApp.path == installed.path else {
      throw AppReplacerError.updateTransactionInvalid
    }
    let installedVersion = try appVersion(at: installed)
    let siblingExists = fileManager.fileExists(atPath: transaction.oldAppSibling.path)

    if transaction.phase == .committed {
      guard installedVersion == transaction.targetVersion else {
        throw AppReplacerError.updateTransactionInvalid
      }
      try validator.validate(app: installed, expectedVersion: transaction.targetVersion)
      if siblingExists {
        try removeReplacement(
          at: transaction.oldAppSibling,
          expectedParent: installed.deletingLastPathComponent(),
          expectedVersion: transaction.previousVersion
        )
      }
      try journal.remove(transaction)
      return .finalized
    }

    guard siblingExists else {
      guard installedVersion == transaction.previousVersion else {
        throw AppReplacerError.updateTransactionInvalid
      }
      try validator.validate(app: installed, expectedVersion: transaction.previousVersion)
      try journal.remove(transaction)
      return .none
    }
    let siblingVersion = try appVersion(at: transaction.oldAppSibling)
    if installedVersion == transaction.targetVersion,
      siblingVersion == transaction.previousVersion
    {
      try validator.validate(app: installed, expectedVersion: transaction.targetVersion)
      try validator.validate(
        app: transaction.oldAppSibling,
        expectedVersion: transaction.previousVersion
      )
      try swap(installed, transaction.oldAppSibling)
      try removeReplacement(
        at: transaction.oldAppSibling,
        expectedParent: installed.deletingLastPathComponent(),
        expectedVersion: transaction.targetVersion
      )
      try journal.remove(transaction)
      return .rolledBack
    }
    if installedVersion == transaction.previousVersion,
      siblingVersion == transaction.targetVersion
    {
      try validator.validate(app: installed, expectedVersion: transaction.previousVersion)
      try removeReplacement(
        at: transaction.oldAppSibling,
        expectedParent: installed.deletingLastPathComponent(),
        expectedVersion: transaction.targetVersion
      )
      try journal.remove(transaction)
      return .finalized
    }
    throw AppReplacerError.updateTransactionInvalid
  }

  private func copyToNewPath(from source: URL, to destination: URL) throws {
    var metadata = stat()
    guard lstat(destination.path, &metadata) != 0 && errno == ENOENT else {
      throw AppReplacerError.unsafeReplacement
    }
    try runCopy(from: source, to: destination)
  }

  private func runCopy(from source: URL, to destination: URL) throws {
    let result = try runner.run(
      executable: Self.ditto,
      arguments: [source.path, destination.path],
      timeout: Self.copyTimeout
    )
    guard result.status == 0 else {
      throw AppReplacerError.copyFailed(result.status)
    }
  }

  private func validateReplacementPaths(
    _ replacement: PreparedReplacement,
    expectedStagedInode: UInt64?
  ) throws {
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
      if url == staged,
        let expectedStagedInode,
        UInt64(metadata.st_ino) != expectedStagedInode
      {
        throw AppReplacerError.unsafeReplacement
      }
    }
  }

  private func appVersion(at app: URL) throws -> SemanticVersion {
    let infoPlist = app.standardizedFileURL.appendingPathComponent(
      "Contents/Info.plist",
      isDirectory: false
    )
    var metadata = stat()
    guard lstat(infoPlist.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size > 0,
      metadata.st_size <= 64 * 1_024,
      infoPlist.resolvingSymlinksInPath().path == infoPlist.path
    else {
      throw AppReplacerError.unsafeReplacement
    }
    let data = try Data(contentsOf: infoPlist, options: [.mappedIfSafe])
    guard
      let plist = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      ) as? [String: Any],
      plist["CFBundleIdentifier"] as? String
        == StagedAppIdentityPolicy.expectedBundleIdentifier,
      let rawVersion = plist["CFBundleShortVersionString"] as? String
    else {
      throw AppReplacerError.unsafeReplacement
    }
    return try SemanticVersion(rawVersion)
  }

  private func record(
    _ source: UpdateTransactionRecord,
    phase: UpdateTransactionPhase
  ) -> UpdateTransactionRecord {
    UpdateTransactionRecord(
      transactionID: source.transactionID,
      installedApp: source.installedApp,
      oldAppSibling: source.oldAppSibling,
      previousVersion: source.previousVersion,
      targetVersion: source.targetVersion,
      phase: phase
    )
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
    expectedVersion: SemanticVersion,
    expectedInode: UInt64? = nil
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
      expectedInode == nil || UInt64(metadata.st_ino) == expectedInode,
      replacement.resolvingSymlinksInPath().path == replacement.path
    else {
      throw AppReplacerError.unsafeReplacement
    }
    try validator.validate(app: replacement, expectedVersion: expectedVersion)
    try fileManager.removeItem(at: replacement)
  }

  private func createOwnedStagingDirectory(at url: URL) throws -> UInt64 {
    guard mkdir(url.path, 0o700) == 0 else {
      throw AppReplacerError.unsafeReplacement
    }
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == geteuid(),
      metadata.st_mode & 0o077 == 0,
      url.resolvingSymlinksInPath().path == url.path
    else {
      throw AppReplacerError.unsafeReplacement
    }
    return UInt64(metadata.st_ino)
  }

  private func removeOwnedStagingDirectory(
    at url: URL,
    expectedParent: URL,
    expectedInode: UInt64
  ) throws {
    let staging = url.standardizedFileURL
    var metadata = stat()
    guard staging.deletingLastPathComponent().path == expectedParent.standardizedFileURL.path,
      staging.lastPathComponent.hasPrefix(".Lidless.update-"),
      staging.lastPathComponent.hasSuffix(".app"),
      lstat(staging.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == geteuid(),
      UInt64(metadata.st_ino) == expectedInode,
      staging.resolvingSymlinksInPath().path == staging.path
    else {
      throw AppReplacerError.unsafeReplacement
    }
    try fileManager.removeItem(at: staging)
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
