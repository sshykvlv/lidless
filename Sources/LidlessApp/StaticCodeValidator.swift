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
  }
}
