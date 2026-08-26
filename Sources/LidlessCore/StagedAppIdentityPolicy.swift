import Foundation

public struct StagedAppIdentityEvidence: Equatable, Sendable {
  public var isRegularBundle: Bool
  public var bundleIdentifier: String?
  public var version: String?
  public var teamIdentifier: String?
  public var signatureValid: Bool
  public var hasHardenedRuntime: Bool
  public var gatekeeperApproved: Bool

  public init(
    isRegularBundle: Bool,
    bundleIdentifier: String?,
    version: String?,
    teamIdentifier: String?,
    signatureValid: Bool,
    hasHardenedRuntime: Bool,
    gatekeeperApproved: Bool
  ) {
    self.isRegularBundle = isRegularBundle
    self.bundleIdentifier = bundleIdentifier
    self.version = version
    self.teamIdentifier = teamIdentifier
    self.signatureValid = signatureValid
    self.hasHardenedRuntime = hasHardenedRuntime
    self.gatekeeperApproved = gatekeeperApproved
  }
}

public enum StagedAppIdentityError: Error, Equatable, Sendable {
  case unsafeBundle
  case wrongBundleIdentifier
  case wrongVersion
  case wrongTeam
  case invalidSignature
  case hardenedRuntimeMissing
  case gatekeeperRejected
}

public enum StagedAppIdentityPolicy {
  public static let expectedBundleIdentifier = "lv.ykv.lidless"
  public static let expectedTeamIdentifier = "J2Q78NFXZX"

  public static func validate(
    _ evidence: StagedAppIdentityEvidence,
    expectedVersion: SemanticVersion
  ) throws {
    guard evidence.isRegularBundle else {
      throw StagedAppIdentityError.unsafeBundle
    }
    guard evidence.bundleIdentifier == expectedBundleIdentifier else {
      throw StagedAppIdentityError.wrongBundleIdentifier
    }
    guard evidence.version == expectedVersion.description else {
      throw StagedAppIdentityError.wrongVersion
    }
    guard evidence.teamIdentifier == expectedTeamIdentifier else {
      throw StagedAppIdentityError.wrongTeam
    }
    guard evidence.signatureValid else {
      throw StagedAppIdentityError.invalidSignature
    }
    guard evidence.hasHardenedRuntime else {
      throw StagedAppIdentityError.hardenedRuntimeMissing
    }
    guard evidence.gatekeeperApproved else {
      throw StagedAppIdentityError.gatekeeperRejected
    }
  }
}
