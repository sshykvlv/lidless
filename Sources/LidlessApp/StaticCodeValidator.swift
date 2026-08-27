import Darwin
import Foundation
import LidlessCore
import Security

enum StaticCodeValidationError: Error, Equatable {
  case unsafeBundle
  case securityFramework(OSStatus)
  case missingSigningInformation
  case gatekeeperOutput
}

final class StaticCodeValidator: StagedAppValidating, @unchecked Sendable {
  static let requirement = CodeSigningRequirements.app

  private let runner: any CommandRunning

  init(runner: any CommandRunning = UpdateProcessRunner()) {
    self.runner = runner
  }

  func validate(app: URL, expectedVersion: SemanticVersion) throws {
    let standardized = app.standardizedFileURL
    var metadata = stat()
    let isRegularBundle =
      standardized.pathExtension == "app"
      && lstat(standardized.path, &metadata) == 0
      && metadata.st_mode & S_IFMT == S_IFDIR
      && standardized.resolvingSymlinksInPath().path == standardized.path

    guard let bundle = Bundle(url: standardized) else {
      throw StaticCodeValidationError.unsafeBundle
    }
    let bundleIdentifier = bundle.bundleIdentifier
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var staticCode: SecStaticCode?
    var result = SecStaticCodeCreateWithPath(standardized as CFURL, [], &staticCode)
    guard result == errSecSuccess, let staticCode else {
      throw StaticCodeValidationError.securityFramework(result)
    }

    var requirement: SecRequirement?
    result = SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement)
    guard result == errSecSuccess, let requirement else {
      throw StaticCodeValidationError.securityFramework(result)
    }

    var validationError: Unmanaged<CFError>?
    result = SecStaticCodeCheckValidityWithErrors(
      staticCode,
      SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
      requirement,
      &validationError
    )
    let signatureValid = result == errSecSuccess

    var signingInformation: CFDictionary?
    let signingResult = SecCodeCopySigningInformation(
      staticCode,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &signingInformation
    )
    guard signingResult == errSecSuccess,
      let information = signingInformation as? [CFString: Any],
      let flags = information[kSecCodeInfoFlags] as? NSNumber
    else {
      throw StaticCodeValidationError.missingSigningInformation
    }
    let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String
    let hardenedRuntimeFlag: UInt32 = 0x1_0000
    let hasHardenedRuntime = flags.uint32Value & hardenedRuntimeFlag == hardenedRuntimeFlag

    let assessment = try runner.run(
      executable: "/usr/sbin/spctl",
      arguments: ["--assess", "--type", "execute", "--verbose=2", standardized.path],
      timeout: 10
    )
    let assessmentLines = (assessment.stdout + "\n" + assessment.stderr)
      .split(whereSeparator: \Character.isNewline)
      .map { $0.lowercased() }
    let acceptedLines = assessmentLines.filter { $0.contains("accepted") }
    let gatekeeperApproved =
      assessment.status == 0
      && acceptedLines.count == 1
      && !assessmentLines.contains(where: { $0.contains("rejected") })

    try StagedAppIdentityPolicy.validate(
      StagedAppIdentityEvidence(
        isRegularBundle: isRegularBundle,
        bundleIdentifier: bundleIdentifier,
        version: version,
        teamIdentifier: teamIdentifier,
        signatureValid: signatureValid,
        hasHardenedRuntime: hasHardenedRuntime,
        gatekeeperApproved: gatekeeperApproved
      ),
      expectedVersion: expectedVersion
    )

    try validateEmbeddedService(in: standardized, expectedVersion: expectedVersion)
  }

  private func validateEmbeddedService(in app: URL, expectedVersion: SemanticVersion) throws {
    let helper = app.appendingPathComponent(
      EmbeddedServiceIdentityPolicy.expectedBundleProgram,
      isDirectory: false
    )
    let daemon = app.appendingPathComponent(
      "Contents/Library/LaunchDaemons/lv.ykv.lidless.helper.plist",
      isDirectory: false
    )
    var helperMetadata = stat()
    var daemonMetadata = stat()
    let helperIsRegularExecutable =
      lstat(helper.path, &helperMetadata) == 0
      && helperMetadata.st_mode & S_IFMT == S_IFREG
      && helperMetadata.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
      && helper.resolvingSymlinksInPath().path == helper.path
    let daemonIsRegularFile =
      lstat(daemon.path, &daemonMetadata) == 0
      && daemonMetadata.st_mode & S_IFMT == S_IFREG
      && daemon.resolvingSymlinksInPath().path == daemon.path

    let daemonData = try Data(contentsOf: daemon, options: [.mappedIfSafe])
    guard daemonData.count <= 64 * 1_024,
      let daemonPlist = try PropertyListSerialization.propertyList(
        from: daemonData,
        options: [],
        format: nil
      ) as? [String: Any]
    else {
      throw StaticCodeValidationError.unsafeBundle
    }
    let machServices = daemonPlist["MachServices"] as? [String: Any]
    let keepAlive = daemonPlist["KeepAlive"] as? [String: Any]

    let signing = try signingEvidence(
      at: helper,
      requirementText: CodeSigningRequirements.helper
    )
    let architecturesResult = try runner.run(
      executable: "/usr/bin/lipo",
      arguments: ["-archs", helper.path],
      timeout: 10
    )
    let architectures: Set<String> =
      architecturesResult.status == 0
      ? Set(
        architecturesResult.stdout.split(whereSeparator: \Character.isWhitespace).map(String.init))
      : []

    let machServiceEnabled =
      (machServices?[EmbeddedServiceIdentityPolicy.expectedIdentifier] as? NSNumber)?.boolValue
      == true
    let runAtLoad = (daemonPlist["RunAtLoad"] as? NSNumber)?.boolValue == true
    let restartAfterFailure = (keepAlive?["SuccessfulExit"] as? NSNumber)?.boolValue == false
    let evidence = EmbeddedServiceIdentityEvidence(
      isRegularExecutable: helperIsRegularExecutable,
      daemonIsRegularFile: daemonIsRegularFile,
      bundleIdentifier: signing.identifier,
      version: signing.version,
      teamIdentifier: signing.teamIdentifier,
      signatureValid: signing.signatureValid,
      hasHardenedRuntime: signing.hasHardenedRuntime,
      architectures: architectures,
      daemonLabel: daemonPlist["Label"] as? String,
      bundleProgram: daemonPlist["BundleProgram"] as? String,
      machServiceEnabled: machServiceEnabled,
      runAtLoad: runAtLoad,
      restartAfterFailure: restartAfterFailure
    )
    try EmbeddedServiceIdentityPolicy.validate(evidence, expectedVersion: expectedVersion)
  }

  private func signingEvidence(at url: URL, requirementText: String) throws -> (
    identifier: String?,
    version: String?,
    teamIdentifier: String?,
    signatureValid: Bool,
    hasHardenedRuntime: Bool
  ) {
    var staticCode: SecStaticCode?
    var result = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
    guard result == errSecSuccess, let staticCode else {
      throw StaticCodeValidationError.securityFramework(result)
    }
    var requirement: SecRequirement?
    result = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
    guard result == errSecSuccess, let requirement else {
      throw StaticCodeValidationError.securityFramework(result)
    }
    let validity = SecStaticCodeCheckValidity(
      staticCode,
      SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
      requirement
    )
    var signingInformation: CFDictionary?
    result = SecCodeCopySigningInformation(
      staticCode,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &signingInformation
    )
    guard result == errSecSuccess,
      let information = signingInformation as? [CFString: Any],
      let flags = information[kSecCodeInfoFlags] as? NSNumber
    else {
      throw StaticCodeValidationError.missingSigningInformation
    }
    let infoPlist = information[kSecCodeInfoPList] as? [String: Any]
    let hardenedRuntimeFlag: UInt32 = 0x1_0000
    return (
      identifier: information[kSecCodeInfoIdentifier] as? String,
      version: infoPlist?["CFBundleShortVersionString"] as? String,
      teamIdentifier: information[kSecCodeInfoTeamIdentifier] as? String,
      signatureValid: validity == errSecSuccess,
      hasHardenedRuntime: flags.uint32Value & hardenedRuntimeFlag == hardenedRuntimeFlag
    )
  }
}
