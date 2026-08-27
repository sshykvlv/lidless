import Foundation

public struct HdiutilMountedEntity: Equatable, Sendable {
  public let device: String
  public let mountPoint: URL

  public init(device: String, mountPoint: URL) {
    self.device = device
    self.mountPoint = mountPoint
  }
}

public enum HdiutilAttachOutputError: Error, Equatable, Sendable {
  case empty
  case oversized
  case malformed
  case ambiguous
}

public enum HdiutilAttachOutput {
  public static let maximumByteCount = 64 * 1_024

  public static func parse(_ output: String) throws -> HdiutilMountedEntity {
    guard !output.isEmpty else {
      throw HdiutilAttachOutputError.empty
    }
    guard output.utf8.count <= maximumByteCount else {
      throw HdiutilAttachOutputError.oversized
    }
    guard
      let plist = try? PropertyListSerialization.propertyList(
        from: Data(output.utf8),
        options: [],
        format: nil
      ),
      let root = plist as? [String: Any],
      let entities = root["system-entities"] as? [[String: Any]]
    else {
      throw HdiutilAttachOutputError.malformed
    }

    let mounted = try entities.compactMap { entity -> HdiutilMountedEntity? in
      guard let mountPoint = entity["mount-point"] else {
        return nil
      }
      guard let path = mountPoint as? String,
        path.hasPrefix("/"),
        !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
        let device = entity["dev-entry"] as? String
      else {
        throw HdiutilAttachOutputError.malformed
      }
      try MountedImagePolicy.validate(device: device)
      return HdiutilMountedEntity(
        device: device,
        mountPoint: URL(fileURLWithPath: path, isDirectory: true)
      )
    }
    guard mounted.count == 1, let result = mounted.first else {
      throw HdiutilAttachOutputError.ambiguous
    }
    return result
  }
}
