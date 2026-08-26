import Foundation
import LidlessCore

enum AppUpdateHelperError: Error, Equatable {
  case normalSleepNotVerified
  case replacementServiceNotVerified
}

@MainActor
final class AppUpdateHelperController: UpdateHelperControlling {
  private let safetyCoordinator: SafetyCoordinator
  private let client: XPCScheduledHelperClient
  private let makeClient: @MainActor @Sendable () -> XPCScheduledHelperClient

  init(
    safetyCoordinator: SafetyCoordinator,
    client: XPCScheduledHelperClient,
    makeClient: @escaping @MainActor @Sendable () -> XPCScheduledHelperClient = {
      XPCScheduledHelperClient()
    }
  ) {
    self.safetyCoordinator = safetyCoordinator
    self.client = client
    self.makeClient = makeClient
  }

  func disarmForUpdate() async throws {
    await safetyCoordinator.disarm(reason: .update)
    try await verifyNormalSleep()
  }

  func restartAfterVerifiedUpdateSwap(expectedVersion: SemanticVersion?) async throws {
    _ = try await client.restartAfterVerifiedUpdateSwap()
    let deadline = ContinuousClock.now + .seconds(10)
    repeat {
      try await Task.sleep(for: .milliseconds(200))
      let replacementClient = makeClient()
      if let status = try? await replacementClient.status(),
        status.status.state == .inactive,
        status.observedSleepDisabled == false,
        expectedVersion == nil || status.buildVersion == expectedVersion?.description
      {
        return
      }
    } while ContinuousClock.now < deadline
    throw AppUpdateHelperError.replacementServiceNotVerified
  }

  private func verifyNormalSleep() async throws {
    let status = try await client.status()
    guard status.status.state == .inactive, status.observedSleepDisabled == false else {
      throw AppUpdateHelperError.normalSleepNotVerified
    }
  }
}
