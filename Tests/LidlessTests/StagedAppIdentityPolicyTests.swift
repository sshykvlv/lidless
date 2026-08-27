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

  func testAcceptsOnlyExactEmbeddedBackgroundServiceContract() throws {
    let expected = try SemanticVersion("1.1.0")
    XCTAssertNoThrow(
      try EmbeddedServiceIdentityPolicy.validate(
        validServiceEvidence(),
        expectedVersion: expected
      )
    )

    var evidence = validServiceEvidence()
    evidence.bundleIdentifier = "lv.ykv.lidless"
    XCTAssertThrowsError(
      try EmbeddedServiceIdentityPolicy.validate(evidence, expectedVersion: expected))
    evidence = validServiceEvidence()
    evidence.daemonLabel = "com.attacker.service"
    XCTAssertThrowsError(
      try EmbeddedServiceIdentityPolicy.validate(evidence, expectedVersion: expected))
    evidence = validServiceEvidence()
    evidence.bundleProgram = "/tmp/tool"
    XCTAssertThrowsError(
      try EmbeddedServiceIdentityPolicy.validate(evidence, expectedVersion: expected))
    evidence = validServiceEvidence()
    evidence.machServiceEnabled = false
    XCTAssertThrowsError(
      try EmbeddedServiceIdentityPolicy.validate(evidence, expectedVersion: expected))
    evidence = validServiceEvidence()
    evidence.architectures = ["arm64"]
    XCTAssertThrowsError(
      try EmbeddedServiceIdentityPolicy.validate(evidence, expectedVersion: expected))
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

  private func validServiceEvidence() -> EmbeddedServiceIdentityEvidence {
    EmbeddedServiceIdentityEvidence(
      isRegularExecutable: true,
      daemonIsRegularFile: true,
      bundleIdentifier: "lv.ykv.lidless.helper",
      version: "1.1.0",
      teamIdentifier: "J2Q78NFXZX",
      signatureValid: true,
      hasHardenedRuntime: true,
      architectures: ["arm64", "x86_64"],
      daemonLabel: "lv.ykv.lidless.helper",
      bundleProgram: "Contents/Library/HelperTools/LidlessHelper",
      machServiceEnabled: true,
      runAtLoad: true,
      restartAfterFailure: true
    )
  }
}
