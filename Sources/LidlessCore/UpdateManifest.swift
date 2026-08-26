import Foundation

public enum UpdateManifestError: Error, Equatable, Sendable {
  case empty
  case oversized
  case malformedLine
  case duplicateFilename
  case unsafeFilename
  case missingFilename
}

public struct UpdateManifest: Equatable, Sendable {
  public static let maximumByteCount = 65_536

  private let hashesByFilename: [String: String]

  public init(_ contents: String) throws {
    guard !contents.isEmpty else {
      throw UpdateManifestError.empty
    }
    guard contents.utf8.count <= Self.maximumByteCount else {
      throw UpdateManifestError.oversized
    }

    var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true {
      lines.removeLast()
    }
    guard !lines.isEmpty, lines.allSatisfy({ !$0.isEmpty }) else {
      throw UpdateManifestError.malformedLine
    }

    var parsed: [String: String] = [:]
    for line in lines {
      let bytes = Array(line.utf8)
      guard bytes.count >= 66,
        bytes.prefix(64).allSatisfy({ byte in
          (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        })
      else {
        throw UpdateManifestError.malformedLine
      }

      var separatorEnd = 64
      guard bytes[separatorEnd] == 32 || bytes[separatorEnd] == 9 else {
        throw UpdateManifestError.malformedLine
      }
      while separatorEnd < bytes.count,
        bytes[separatorEnd] == 32 || bytes[separatorEnd] == 9
      {
        separatorEnd += 1
      }
      guard separatorEnd < bytes.count,
        let filename = String(bytes: bytes[separatorEnd...], encoding: .utf8)
      else {
        throw UpdateManifestError.malformedLine
      }
      try Self.validate(filename: filename)

      guard parsed[filename] == nil else {
        throw UpdateManifestError.duplicateFilename
      }
      parsed[filename] = String(decoding: bytes.prefix(64), as: UTF8.self)
    }
    hashesByFilename = parsed
  }

  public func expectedSHA256(for filename: String) throws -> String {
    try Self.validate(filename: filename)
    guard let hash = hashesByFilename[filename] else {
      throw UpdateManifestError.missingFilename
    }
    return hash
  }

  private static func validate(filename: String) throws {
    guard !filename.isEmpty,
      filename != ".",
      filename != "..",
      !filename.contains("/"),
      !filename.contains("\\"),
      filename.unicodeScalars.allSatisfy({
        !CharacterSet.controlCharacters.contains($0)
      })
    else {
      throw UpdateManifestError.unsafeFilename
    }
  }
}
