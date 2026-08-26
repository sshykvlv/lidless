import Darwin
import Foundation

public enum LegacyGrantFileKind: Equatable, Sendable {
  case regular
  case symbolicLink
  case other
}

public struct LegacyGrantFile: Equatable, Sendable {
  public let path: String
  public let kind: LegacyGrantFileKind
  public let ownerUID: UInt32
  public let mode: UInt16
  public let byteCount: Int
  public let contents: Data

  public init(
    path: String,
    kind: LegacyGrantFileKind,
    ownerUID: UInt32,
    mode: UInt16,
    byteCount: Int,
    contents: Data
  ) {
    self.path = path
    self.kind = kind
    self.ownerUID = ownerUID
    self.mode = mode
    self.byteCount = byteCount
    self.contents = contents
  }
}

public enum LegacyGrantRemovalResult: Equatable, Sendable {
  case notFound
  case notEligible
  case removed
  case manualCleanupRequired
}

public protocol LegacyGrantFileSystem: AnyObject {
  func inspect(path: String, maximumBytes: Int) throws -> LegacyGrantFile?
  func unlink(path: String) throws
}

public struct LegacyGrantPOSIXError: Error, Equatable, Sendable {
  public let operation: String
  public let code: Int32

  public init(operation: String, code: Int32) {
    self.operation = operation
    self.code = code
  }
}

public final class POSIXLegacyGrantFileSystem: LegacyGrantFileSystem {
  public init() {}

  public func inspect(path: String, maximumBytes: Int) throws -> LegacyGrantFile? {
    var metadata = stat()
    let status = path.withCString { Darwin.lstat($0, &metadata) }
    if status != 0 {
      if errno == ENOENT {
        return nil
      }
      throw posixError("lstat legacy grant")
    }

    let kind = fileKind(mode: metadata.st_mode)
    guard kind == .regular else {
      return makeFile(path: path, metadata: metadata, kind: kind, contents: Data())
    }
    guard metadata.st_size >= 0, metadata.st_size <= maximumBytes else {
      return makeFile(path: path, metadata: metadata, kind: kind, contents: Data())
    }

    let descriptor = try openReadOnly(path: path)
    defer { _ = Darwin.close(descriptor) }

    var openedMetadata = stat()
    guard Darwin.fstat(descriptor, &openedMetadata) == 0 else {
      throw posixError("fstat legacy grant")
    }
    guard openedMetadata.st_dev == metadata.st_dev,
      openedMetadata.st_ino == metadata.st_ino,
      fileKind(mode: openedMetadata.st_mode) == .regular
    else {
      return makeFile(path: path, metadata: openedMetadata, kind: .other, contents: Data())
    }

    let contents = try readBounded(descriptor: descriptor, maximumBytes: maximumBytes)
    return makeFile(path: path, metadata: openedMetadata, kind: .regular, contents: contents)
  }

  public func unlink(path: String) throws {
    let result = path.withCString { Darwin.unlink($0) }
    guard result == 0 else {
      throw posixError("unlink legacy grant")
    }
  }

  private func openReadOnly(path: String) throws -> Int32 {
    let descriptor = path.withCString { pointer in
      let openWithoutMode: (UnsafePointer<CChar>, Int32) -> Int32 = Darwin.open
      return openWithoutMode(pointer, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      throw posixError("open legacy grant")
    }
    return descriptor
  }

  private func readBounded(descriptor: Int32, maximumBytes: Int) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: min(512, maximumBytes + 1))

    while result.count <= maximumBytes {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count < 0 {
        if errno == EINTR {
          continue
        }
        throw posixError("read legacy grant")
      }
      if count == 0 {
        break
      }
      result.append(buffer, count: count)
      if result.count > maximumBytes {
        break
      }
    }
    return result
  }

  private func makeFile(
    path: String,
    metadata: stat,
    kind: LegacyGrantFileKind,
    contents: Data
  ) -> LegacyGrantFile {
    LegacyGrantFile(
      path: path,
      kind: kind,
      ownerUID: metadata.st_uid,
      mode: UInt16(metadata.st_mode & mode_t(0o7777)),
      byteCount: max(0, Int(metadata.st_size)),
      contents: contents
    )
  }

  private func fileKind(mode: mode_t) -> LegacyGrantFileKind {
    switch mode & mode_t(S_IFMT) {
    case mode_t(S_IFREG):
      return .regular
    case mode_t(S_IFLNK):
      return .symbolicLink
    default:
      return .other
    }
  }

  private func posixError(_ operation: String) -> LegacyGrantPOSIXError {
    LegacyGrantPOSIXError(operation: operation, code: errno)
  }
}

public final class LegacyGrantMigrator {
  public static let knownPaths = [
    "/etc/sudoers.d/lidless",
    "/etc/sudoers.d/keepawake",
  ]
  public static let maximumBytes = 512

  private static let recognizedRuleSuffixes = [
    " ALL=(ALL) NOPASSWD: /usr/bin/pmset",
    " ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1",
  ]

  private let filesystem: any LegacyGrantFileSystem

  public init(filesystem: any LegacyGrantFileSystem = POSIXLegacyGrantFileSystem()) {
    self.filesystem = filesystem
  }

  public func removeRecognizedGrants() throws -> LegacyGrantRemovalResult {
    var removedAny = false
    var requiresManualCleanup = false

    for path in Self.knownPaths {
      guard let file = try filesystem.inspect(path: path, maximumBytes: Self.maximumBytes) else {
        continue
      }
      switch try removeIfRecognized(file) {
      case .removed:
        removedAny = true
      case .manualCleanupRequired:
        requiresManualCleanup = true
      case .notFound, .notEligible:
        break
      }
    }

    if requiresManualCleanup {
      return .manualCleanupRequired
    }
    return removedAny ? .removed : .notFound
  }

  public func removeIfRecognized(_ file: LegacyGrantFile) throws -> LegacyGrantRemovalResult {
    guard Self.knownPaths.contains(file.path) else {
      return .notEligible
    }
    guard file.kind == .regular,
      file.ownerUID == 0,
      permissionsAreNoBroaderThanReadOnly(file.mode),
      file.byteCount <= Self.maximumBytes,
      file.byteCount == file.contents.count,
      isRecognizedRule(file.contents)
    else {
      return .manualCleanupRequired
    }

    try filesystem.unlink(path: file.path)
    return .removed
  }

  private func permissionsAreNoBroaderThanReadOnly(_ mode: UInt16) -> Bool {
    let allowed = UInt16(0o440)
    return mode & ~allowed == 0
  }

  private func isRecognizedRule(_ data: Data) -> Bool {
    guard var rule = String(data: data, encoding: .utf8) else {
      return false
    }
    if rule.hasSuffix("\n") {
      rule.removeLast()
      if rule.hasSuffix("\r") {
        rule.removeLast()
      }
    }
    guard !rule.contains("\n"), !rule.contains("\r"),
      let separator = rule.firstIndex(of: " ")
    else {
      return false
    }

    let username = String(rule[..<separator])
    let suffix = String(rule[separator...])
    return validUsername(username) && Self.recognizedRuleSuffixes.contains(suffix)
  }

  private func validUsername(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first,
      CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first)
    else {
      return false
    }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    return value.unicodeScalars.allSatisfy(allowed.contains)
  }
}
