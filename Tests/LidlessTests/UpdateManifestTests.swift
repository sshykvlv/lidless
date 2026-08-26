import XCTest

@testable import LidlessCore

final class UpdateManifestTests: XCTestCase {
  func testReturnsOneExactLowercaseSHAForLidlessAssets() throws {
    let diskHash = String(repeating: "a", count: 64)
    let archiveHash = String(repeating: "b", count: 64)
    let manifest = try UpdateManifest(
      "\(diskHash)  Lidless.dmg\n\(archiveHash)  Lidless.zip\n"
    )

    XCTAssertEqual(try manifest.expectedSHA256(for: "Lidless.dmg"), diskHash)
    XCTAssertEqual(try manifest.expectedSHA256(for: "Lidless.zip"), archiveHash)
  }

  func testRejectsMissingDuplicateMalformedAndOversizedManifest() throws {
    XCTAssertThrowsError(try UpdateManifest("").expectedSHA256(for: "Lidless.dmg"))
    let hash = String(repeating: "b", count: 64)
    XCTAssertThrowsError(
      try UpdateManifest("\(hash)  Lidless.dmg\n\(hash)  Lidless.dmg\n")
        .expectedSHA256(for: "Lidless.dmg")
    )
    for value in [
      "xyz  Lidless.dmg\n",
      "\(String(repeating: "A", count: 64))  Lidless.dmg\n",
      "\(hash)Lidless.dmg\n",
      "\(hash)  ../Lidless.dmg\n",
      "\(hash)  nested/Lidless.dmg\n",
      "\(hash)  nested\\Lidless.dmg\n",
      "\(hash)  Lidless.dmg\u{0000}\n",
    ] {
      XCTAssertThrowsError(try UpdateManifest(value))
    }
    XCTAssertThrowsError(try UpdateManifest(String(repeating: "x", count: 65_537)))
  }

  func testRejectsUnsafeRequestedFilename() throws {
    let hash = String(repeating: "c", count: 64)
    let manifest = try UpdateManifest("\(hash)  Lidless.dmg\n")

    for filename in ["", "../Lidless.dmg", "nested/Lidless.dmg", "Lidless\\.dmg"] {
      XCTAssertThrowsError(try manifest.expectedSHA256(for: filename))
    }
  }

  func testAcceptsSingleWhitespaceOrDoubleSpaceSeparator() throws {
    let hash = String(repeating: "d", count: 64)
    XCTAssertEqual(
      try UpdateManifest("\(hash) Lidless.dmg\n").expectedSHA256(for: "Lidless.dmg"),
      hash
    )
    XCTAssertEqual(
      try UpdateManifest("\(hash)  Lidless.dmg\n").expectedSHA256(for: "Lidless.dmg"),
      hash
    )
  }
}
