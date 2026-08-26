import Foundation
import XCTest

@testable import LidlessCore

final class StagedAppIdentityPolicyTests: XCTestCase {
  func testAcceptsExactSignedHardenedGatekeeperApprovedApp() throws {
    let expected = try SemanticVersion("1.1.0")
    XCTAssertNoThrow(
      try StagedAppIdentityPolicy.validate(validEvidence(), expectedVersion: expected))
  }

  func testRejectsWrongVersionBundleTeamSignatureRuntimeAndGatekeeper() throws {
    let expected = try SemanticVersion("1.1.0")
    var evidence = validEvidence()

    evidence.version = "1.0.0"
    XCTAssertThrowsError(try StagedAppIdentityPolicy.validate(evidence, expectedVersion: expected))
    evidence = validEvidence()
    evidence.bundleIdentifier = "com.attacker.Lidless"
    XCTAssertThrowsError(try StagedAppIdentityPolicy.validate(evidence, expectedVersion: expected))
    evidence = validEvidence()
    evidence.teamIdentifier = "ATTACKER123"
    XCTAssertThrowsError(try StagedAppIdentityPolicy.validate(evidence, expectedVersion: expected))
    evidence = validEvidence()
    evidence.signatureValid = false
    XCTAssertThrowsError(try StagedAppIdentityPolicy.validate(evidence, expectedVersion: expected))
    evidence = validEvidence()
    evidence.hasHardenedRuntime = false
    XCTAssertThrowsError(try StagedAppIdentityPolicy.validate(evidence, expectedVersion: expected))
    evidence = validEvidence()
    evidence.gatekeeperApproved = false
    XCTAssertThrowsError(try StagedAppIdentityPolicy.validate(evidence, expectedVersion: expected))
  }

  private func validEvidence() -> StagedAppIdentityEvidence {
    StagedAppIdentityEvidence(
      isRegularBundle: true,
      bundleIdentifier: "lv.ykv.lidless",
      version: "1.1.0",
      teamIdentifier: "J2Q78NFXZX",
      signatureValid: true,
      hasHardenedRuntime: true,
      gatekeeperApproved: true
    )
  }
}
