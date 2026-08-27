import XCTest

@testable import LidlessCore

final class LatestReleaseMetadataTests: XCTestCase {
  func testAcceptsExactTagAndRequiredAssetNames() throws {
    let json = """
      {
        "tag_name": "v1.1.0",
        "assets": [
          {"name": "Lidless.dmg", "browser_download_url": "https://attacker.invalid/a"},
          {"name": "Lidless.zip", "browser_download_url": "https://attacker.invalid/b"},
          {"name": "SHA256SUMS", "browser_download_url": "https://attacker.invalid/c"}
        ]
      }
      """

    let release = try LatestReleaseMetadata(json).release

    XCTAssertEqual(release.version, try SemanticVersion("1.1.0"))
    XCTAssertEqual(
      release.diskImageURL.host,
      "github.com",
      "The parser must derive fixed URLs instead of trusting browser_download_url"
    )
  }

  func testRejectsMissingDuplicateMalformedAndOversizedResponses() {
    for json in [
      "{}",
      #"{"tag_name":"latest","assets":[]}"#,
      #"{"tag_name":"v1.1.0","assets":[{"name":"Lidless.dmg"}]}"#,
      #"{"tag_name":"v1.1.0","assets":[{"name":"SHA256SUMS"}]}"#,
      #"{"tag_name":"v1.1.0","assets":[{"name":"Lidless.dmg"},{"name":"Lidless.dmg"},{"name":"SHA256SUMS"}]}"#,
      "not json",
      String(repeating: "x", count: 65_537),
    ] {
      XCTAssertThrowsError(try LatestReleaseMetadata(json), "Accepted unsafe release JSON")
    }
  }
}
