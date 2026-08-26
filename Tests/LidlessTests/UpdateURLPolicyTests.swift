import Foundation
import XCTest

@testable import LidlessCore

final class UpdateURLPolicyTests: XCTestCase {
  func testAcceptsPublicHTTPSWithoutCredentials() throws {
    XCTAssertNoThrow(
      try UpdateURLPolicy.validate(
        URL(string: "https://github.com/sshykvlv/lidless/releases/download/v1.1.0/Lidless.dmg")!
      )
    )
    XCTAssertNoThrow(
      try UpdateURLPolicy.validate(URL(string: "https://objects.githubusercontent.com/file")!)
    )
  }

  func testRejectsUnsafeSchemesPortsCredentialsAndLocalDestinations() {
    for value in [
      "http://github.com/file",
      "file:///tmp/Lidless.dmg",
      "https://user:password@example.com/file",
      "https://example.com:444/file",
      "https://localhost/file",
      "https://updates.local/file",
      "https://updates.local./file",
      "https://127.0.0.1/file",
      "https://127.4.3.2/file",
      "https://10.0.0.1/file",
      "https://172.16.0.1/file",
      "https://192.168.1.1/file",
      "https://169.254.10.20/file",
      "https://0.0.0.0/file",
      "https://[::1]/file",
      "https://[fe80::1]/file",
      "https://[fd00::1]/file",
      "https://[::ffff:10.0.0.1]/file",
      "https://[::ffff:172.16.0.1]/file",
      "https://[::ffff:192.168.1.1]/file",
      "https://[::ffff:100.64.0.1]/file",
    ] {
      XCTAssertThrowsError(
        try UpdateURLPolicy.validate(URL(string: value)!),
        "Accepted unsafe update URL \(value)"
      )
    }
  }

  func testRejectsCredentialBearingRequests() {
    var request = URLRequest(url: URL(string: "https://github.com/release")!)
    request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    XCTAssertThrowsError(try UpdateURLPolicy.validate(request))

    request.setValue(nil, forHTTPHeaderField: "Authorization")
    request.setValue("session=secret", forHTTPHeaderField: "Cookie")
    XCTAssertThrowsError(try UpdateURLPolicy.validate(request))
  }
}
