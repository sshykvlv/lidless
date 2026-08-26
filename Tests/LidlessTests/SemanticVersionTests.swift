import XCTest

@testable import LidlessCore

final class SemanticVersionTests: XCTestCase {
  func testComparesNormalizedThreePartVersions() throws {
    XCTAssertLessThan(try SemanticVersion("1.0.1"), try SemanticVersion("1.1.0"))
    XCTAssertEqual(try SemanticVersion("v1.1.0"), try SemanticVersion("1.1.0"))
    XCTAssertGreaterThan(try SemanticVersion("2.0.0"), try SemanticVersion("1.999.999"))
  }

  func testRejectsMalformedOrUnboundedVersions() {
    for value in [
      "1", "1.1", "1.1.0.0", "1.1.-1", "1.1.0/../../x", " 1.1.0", "1.1.0 ",
      "01.1.0", "1.01.0", "1.1.00", "65536.0.0", String(repeating: "1", count: 65),
    ] {
      XCTAssertThrowsError(try SemanticVersion(value), "Accepted malformed version \(value)")
    }
  }

  func testReleaseDescriptorDerivesOnlyFixedGitHubAssets() throws {
    let release = ReleaseDescriptor(version: try SemanticVersion("1.1.0"))

    XCTAssertEqual(
      release.diskImageURL.absoluteString,
      "https://github.com/sshykvlv/lidless/releases/download/v1.1.0/Lidless.dmg"
    )
    XCTAssertEqual(
      release.archiveURL.absoluteString,
      "https://github.com/sshykvlv/lidless/releases/download/v1.1.0/Lidless.zip"
    )
    XCTAssertEqual(
      release.manifestURL.absoluteString,
      "https://github.com/sshykvlv/lidless/releases/download/v1.1.0/SHA256SUMS"
    )
  }
}
