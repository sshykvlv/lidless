import Darwin
import Foundation
import LidlessCore

enum UpdateTransactionPhase: Int, Codable, Comparable, Sendable {
  case prepared
  case swapped
  case committed

  static func < (lhs: UpdateTransactionPhase, rhs: UpdateTransactionPhase) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

struct UpdateTransactionRecord: Codable, Equatable, Sendable {
  let transactionID: UUID
  let installedApp: URL
  let oldAppSibling: URL
  let previousVersion: SemanticVersion
  let targetVersion: SemanticVersion
  let phase: UpdateTransactionPhase
  let appBundleIdentifier: String
  let serviceBundleIdentifier: String
  let teamIdentifier: String

  init(
    transactionID: UUID,
    installedApp: URL,
    oldAppSibling: URL,
    previousVersion: SemanticVersion,
    targetVersion: SemanticVersion,
    phase: UpdateTransactionPhase
  ) {
    self.transactionID = transactionID
    self.installedApp = installedApp.standardizedFileURL
    self.oldAppSibling = oldAppSibling.standardizedFileURL
    self.previousVersion = previousVersion
    self.targetVersion = targetVersion
    self.phase = phase
    appBundleIdentifier = StagedAppIdentityPolicy.expectedBundleIdentifier
    serviceBundleIdentifier = EmbeddedServiceIdentityPolicy.expectedIdentifier
    teamIdentifier = StagedAppIdentityPolicy.expectedTeamIdentifier
  }

  private enum CodingKeys: String, CodingKey {
    case transactionID
    case installedApp
    case oldAppSibling
    case previousVersion
    case targetVersion
    case phase
    case appBundleIdentifier
    case serviceBundleIdentifier
    case teamIdentifier
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    transactionID = try container.decode(UUID.self, forKey: .transactionID)
    installedApp =
      URL(
        fileURLWithPath: try container.decode(String.self, forKey: .installedApp),
        isDirectory: true
      ).standardizedFileURL
    oldAppSibling =
      URL(
        fileURLWithPath: try container.decode(String.self, forKey: .oldAppSibling),
        isDirectory: true
      ).standardizedFileURL
    previousVersion = try SemanticVersion(
      container.decode(String.self, forKey: .previousVersion))
    targetVersion = try SemanticVersion(container.decode(String.self, forKey: .targetVersion))
    phase = try container.decode(UpdateTransactionPhase.self, forKey: .phase)
    appBundleIdentifier = try container.decode(String.self, forKey: .appBundleIdentifier)
    serviceBundleIdentifier = try container.decode(String.self, forKey: .serviceBundleIdentifier)
    teamIdentifier = try container.decode(String.self, forKey: .teamIdentifier)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(transactionID, forKey: .transactionID)
    try container.encode(installedApp.path, forKey: .installedApp)
    try container.encode(oldAppSibling.path, forKey: .oldAppSibling)
    try container.encode(previousVersion.description, forKey: .previousVersion)
    try container.encode(targetVersion.description, forKey: .targetVersion)
    try container.encode(phase, forKey: .phase)
    try container.encode(appBundleIdentifier, forKey: .appBundleIdentifier)
    try container.encode(serviceBundleIdentifier, forKey: .serviceBundleIdentifier)
    try container.encode(teamIdentifier, forKey: .teamIdentifier)
  }
}

enum UpdateTransactionJournalError: Error, Equatable {
  case unsafeRecord
  case unsafeJournal
  case corruptJournal
  case conflictingTransaction
  case phaseRegression
  case io(Int32)
}

final class DurableUpdateTransactionJournal: @unchecked Sendable {
  private static let fileName = ".Lidless.update-transaction.json"
  private static let maximumBytes = 16 * 1_024

  func store(_ record: UpdateTransactionRecord) throws {
    try validate(record)
    if let existing = try load(installedApp: record.installedApp) {
      guard sameTransaction(existing, record) else {
        throw UpdateTransactionJournalError.conflictingTransaction
      }
      guard record.phase >= existing.phase else {
        throw UpdateTransactionJournalError.phaseRegression
      }
    } else if record.phase != .prepared {
      throw UpdateTransactionJournalError.phaseRegression
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(record)
    guard !data.isEmpty, data.count <= Self.maximumBytes else {
      throw UpdateTransactionJournalError.unsafeRecord
    }
    try writeAtomically(data, to: journalURL(for: record.installedApp))
  }

  func load(installedApp: URL) throws -> UpdateTransactionRecord? {
    let url = journalURL(for: installedApp)
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw UpdateTransactionJournalError.io(errno)
    }
    defer { close(descriptor) }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw UpdateTransactionJournalError.io(errno)
    }
    guard metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(),
      metadata.st_mode & 0o077 == 0,
      metadata.st_size > 0,
      metadata.st_size <= Self.maximumBytes
    else {
      throw UpdateTransactionJournalError.unsafeJournal
    }
    let data = try readExactly(descriptor, count: Int(metadata.st_size))
    let record: UpdateTransactionRecord
    do {
      record = try JSONDecoder().decode(UpdateTransactionRecord.self, from: data)
    } catch {
      throw UpdateTransactionJournalError.corruptJournal
    }
    try validate(record)
    guard record.installedApp.path == installedApp.standardizedFileURL.path else {
      throw UpdateTransactionJournalError.unsafeRecord
    }
    return record
  }

  func remove(_ record: UpdateTransactionRecord) throws {
    guard let existing = try load(installedApp: record.installedApp) else { return }
    guard existing == record else {
      throw UpdateTransactionJournalError.conflictingTransaction
    }
    let url = journalURL(for: record.installedApp)
    guard unlink(url.path) == 0 else {
      throw UpdateTransactionJournalError.io(errno)
    }
    try syncDirectory(url.deletingLastPathComponent())
  }

  func journalURL(for installedApp: URL) -> URL {
    installedApp.standardizedFileURL.deletingLastPathComponent()
      .appendingPathComponent(Self.fileName, isDirectory: false)
  }

  private func validate(_ record: UpdateTransactionRecord) throws {
    let installed = record.installedApp.standardizedFileURL
    let sibling = record.oldAppSibling.standardizedFileURL
    let parent = installed.deletingLastPathComponent()
    guard installed.isFileURL,
      sibling.isFileURL,
      installed.lastPathComponent == "Lidless.app",
      parent.path != "/",
      sibling.deletingLastPathComponent().path == parent.path,
      sibling.lastPathComponent.hasPrefix(".Lidless.update-"),
      sibling.lastPathComponent.hasSuffix(".app"),
      record.targetVersion > record.previousVersion,
      record.appBundleIdentifier == StagedAppIdentityPolicy.expectedBundleIdentifier,
      record.serviceBundleIdentifier == EmbeddedServiceIdentityPolicy.expectedIdentifier,
      record.teamIdentifier == StagedAppIdentityPolicy.expectedTeamIdentifier
    else {
      throw UpdateTransactionJournalError.unsafeRecord
    }
  }

  private func sameTransaction(
    _ first: UpdateTransactionRecord,
    _ second: UpdateTransactionRecord
  ) -> Bool {
    first.transactionID == second.transactionID
      && first.installedApp == second.installedApp
      && first.oldAppSibling == second.oldAppSibling
      && first.previousVersion == second.previousVersion
      && first.targetVersion == second.targetVersion
      && first.appBundleIdentifier == second.appBundleIdentifier
      && first.serviceBundleIdentifier == second.serviceBundleIdentifier
      && first.teamIdentifier == second.teamIdentifier
  }

  private func writeAtomically(_ data: Data, to destination: URL) throws {
    let parent = destination.deletingLastPathComponent()
    let temporary = parent.appendingPathComponent(
      ".Lidless.update-transaction.\(UUID().uuidString).tmp",
      isDirectory: false
    )
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw UpdateTransactionJournalError.io(errno)
    }
    var needsClose = true
    defer {
      if needsClose { close(descriptor) }
      unlink(temporary.path)
    }
    try writeAll(data, to: descriptor)
    guard fsync(descriptor) == 0 else {
      throw UpdateTransactionJournalError.io(errno)
    }
    guard close(descriptor) == 0 else {
      needsClose = false
      throw UpdateTransactionJournalError.io(errno)
    }
    needsClose = false
    guard rename(temporary.path, destination.path) == 0 else {
      throw UpdateTransactionJournalError.io(errno)
    }
    try syncDirectory(parent)
  }

  private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
        guard written > 0 else {
          throw UpdateTransactionJournalError.io(errno)
        }
        offset += written
      }
    }
  }

  private func readExactly(_ descriptor: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < count {
        let received = Darwin.read(descriptor, base.advanced(by: offset), count - offset)
        guard received > 0 else {
          throw UpdateTransactionJournalError.corruptJournal
        }
        offset += received
      }
    }
    return data
  }

  private func syncDirectory(_ directory: URL) throws {
    let descriptor = open(directory.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw UpdateTransactionJournalError.io(errno)
    }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw UpdateTransactionJournalError.io(errno)
    }
  }
}
