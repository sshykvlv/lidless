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

public struct EmbeddedServiceIdentityEvidence: Equatable, Sendable {
  public var isRegularExecutable: Bool
  public var daemonIsRegularFile: Bool
  public var bundleIdentifier: String?
  public var version: String?
  public var teamIdentifier: String?
  public var signatureValid: Bool
  public var hasHardenedRuntime: Bool
  public var architectures: Set<String>
  public var daemonLabel: String?
  public var bundleProgram: String?
  public var machServiceEnabled: Bool
  public var runAtLoad: Bool
  public var restartAfterFailure: Bool

  public init(
    isRegularExecutable: Bool,
    daemonIsRegularFile: Bool,
    bundleIdentifier: String?,
    version: String?,
    teamIdentifier: String?,
    signatureValid: Bool,
    hasHardenedRuntime: Bool,
    architectures: Set<String>,
    daemonLabel: String?,
    bundleProgram: String?,
    machServiceEnabled: Bool,
    runAtLoad: Bool,
    restartAfterFailure: Bool
  ) {
    self.isRegularExecutable = isRegularExecutable
    self.daemonIsRegularFile = daemonIsRegularFile
    self.bundleIdentifier = bundleIdentifier
    self.version = version
    self.teamIdentifier = teamIdentifier
    self.signatureValid = signatureValid
    self.hasHardenedRuntime = hasHardenedRuntime
    self.architectures = architectures
    self.daemonLabel = daemonLabel
    self.bundleProgram = bundleProgram
    self.machServiceEnabled = machServiceEnabled
    self.runAtLoad = runAtLoad
    self.restartAfterFailure = restartAfterFailure
  }
}

public enum EmbeddedServiceIdentityError: Error, Equatable, Sendable {
  case unsafeFiles
  case wrongBundleIdentifier
  case wrongVersion
  case wrongTeam
  case invalidSignature
  case hardenedRuntimeMissing
  case wrongArchitectures
  case wrongDaemonConfiguration
}

public enum EmbeddedServiceIdentityPolicy {
  public static let expectedIdentifier = "lv.ykv.lidless.helper"
  public static let expectedBundleProgram = "Contents/Library/HelperTools/LidlessHelper"

  public static func validate(
    _ evidence: EmbeddedServiceIdentityEvidence,
    expectedVersion: SemanticVersion
  ) throws {
    guard evidence.isRegularExecutable, evidence.daemonIsRegularFile else {
      throw EmbeddedServiceIdentityError.unsafeFiles
    }
    guard evidence.bundleIdentifier == expectedIdentifier else {
      throw EmbeddedServiceIdentityError.wrongBundleIdentifier
    }
    guard evidence.version == expectedVersion.description else {
      throw EmbeddedServiceIdentityError.wrongVersion
    }
    guard evidence.teamIdentifier == StagedAppIdentityPolicy.expectedTeamIdentifier else {
      throw EmbeddedServiceIdentityError.wrongTeam
    }
    guard evidence.signatureValid else {
      throw EmbeddedServiceIdentityError.invalidSignature
    }
    guard evidence.hasHardenedRuntime else {
      throw EmbeddedServiceIdentityError.hardenedRuntimeMissing
    }
    guard evidence.architectures == ["arm64", "x86_64"] else {
      throw EmbeddedServiceIdentityError.wrongArchitectures
    }
    guard evidence.daemonLabel == expectedIdentifier,
      evidence.bundleProgram == expectedBundleProgram,
      evidence.machServiceEnabled,
      evidence.runAtLoad,
      evidence.restartAfterFailure
    else {
      throw EmbeddedServiceIdentityError.wrongDaemonConfiguration
    }
  }
}
