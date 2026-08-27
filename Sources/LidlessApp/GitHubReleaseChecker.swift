import Foundation
import LidlessCore

enum GitHubReleaseCheckerError: Error, Equatable {
  case invalidEndpoint
}

final class GitHubReleaseChecker: @unchecked Sendable {
  private static let endpoint =
    "https://api.github.com/repos/sshykvlv/lidless/releases/latest"

  private let downloader: any UpdateDownloading

  init(downloader: any UpdateDownloading) {
    self.downloader = downloader
  }

  func latest() async throws -> ReleaseDescriptor {
    guard let url = URL(string: Self.endpoint) else {
      throw GitHubReleaseCheckerError.invalidEndpoint
    }
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("Lidless", forHTTPHeaderField: "User-Agent")
    let json = try await downloader.text(
      request,
      maximumBytes: LatestReleaseMetadata.maximumByteCount
    )
    return try LatestReleaseMetadata(json).release
  }
}
