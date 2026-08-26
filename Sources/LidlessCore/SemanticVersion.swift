import Foundation

public enum SemanticVersionError: Error, Equatable, Sendable {
  case invalid
}

public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
  public let major: UInt16
  public let minor: UInt16
  public let patch: UInt16

  public init(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 64 else {
      throw SemanticVersionError.invalid
    }

    let normalized = value.first == "v" ? String(value.dropFirst()) : value
    let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3 else {
      throw SemanticVersionError.invalid
    }

    let parsed = try components.map(Self.parseComponent)
    major = parsed[0]
    minor = parsed[1]
    patch = parsed[2]
  }

  public var description: String {
    "\(major).\(minor).\(patch)"
  }

  public var tag: String {
    "v\(description)"
  }

  public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }

  private static func parseComponent(_ value: Substring) throws -> UInt16 {
    guard !value.isEmpty,
      value == "0" || value.first != "0",
      value.utf8.allSatisfy({ byte in byte >= 48 && byte <= 57 }),
      let parsed = UInt16(value)
    else {
      throw SemanticVersionError.invalid
    }
    return parsed
  }
}
