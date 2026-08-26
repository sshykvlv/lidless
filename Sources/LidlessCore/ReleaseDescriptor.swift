import Foundation

public struct ReleaseDescriptor: Equatable, Sendable {
  public let version: SemanticVersion
  public let diskImageURL: URL
  public let archiveURL: URL
  public let manifestURL: URL

  public init(version: SemanticVersion) {
    self.version = version
    let base = "https://github.com/sshykvlv/lidless/releases/download/\(version.tag)"
    guard let diskImageURL = URL(string: "\(base)/Lidless.dmg"),
      let archiveURL = URL(string: "\(base)/Lidless.zip"),
      let manifestURL = URL(string: "\(base)/SHA256SUMS")
    else {
      preconditionFailure("Fixed Lidless release URLs must be valid")
    }
    self.diskImageURL = diskImageURL
    self.archiveURL = archiveURL
    self.manifestURL = manifestURL
  }
}
