import Foundation

public enum LatestReleaseMetadataError: Error, Equatable, Sendable {
  case empty
  case oversized
  case malformed
  case invalidTag
  case missingRequiredAsset
  case duplicateRequiredAsset
}

public struct LatestReleaseMetadata: Equatable, Sendable {
  public static let maximumByteCount = 64 * 1_024

  public let release: ReleaseDescriptor

  public init(_ json: String) throws {
    guard !json.isEmpty else {
      throw LatestReleaseMetadataError.empty
    }
    guard json.utf8.count <= Self.maximumByteCount else {
      throw LatestReleaseMetadataError.oversized
    }
    guard let response = try? JSONDecoder().decode(Response.self, from: Data(json.utf8)) else {
      throw LatestReleaseMetadataError.malformed
    }
    guard response.tagName.first == "v",
      let version = try? SemanticVersion(response.tagName)
    else {
      throw LatestReleaseMetadataError.invalidTag
    }

    let names = response.assets.map(\.name)
    for required in ["Lidless.dmg", "SHA256SUMS"] {
      let count = names.filter { $0 == required }.count
      guard count > 0 else {
        throw LatestReleaseMetadataError.missingRequiredAsset
      }
      guard count == 1 else {
        throw LatestReleaseMetadataError.duplicateRequiredAsset
      }
    }
    release = ReleaseDescriptor(version: version)
  }
}

private struct Response: Decodable {
  let tagName: String
  let assets: [Asset]

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case assets
  }
}

private struct Asset: Decodable {
  let name: String
}
