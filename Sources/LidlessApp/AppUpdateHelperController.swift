import Foundation
import LidlessCore

enum AppUpdateHelperError: Error, Equatable {
  case normalSleepNotVerified
}

@MainActor
final class AppUpdateHelperController: UpdateHelperControlling {
  private let safetyCoordinator: SafetyCoordinator
  private let client: XPCScheduledHelperClient

  init(safetyCoordinator: SafetyCoordinator, client: XPCScheduledHelperClient) {
    self.safetyCoordinator = safetyCoordinator
    self.client = client
  }

  func disarmForUpdate() async throws {
    await safetyCoordinator.disarm(reason: .update)
    try await verifyNormalSleep()
  }

  func restartAfterVerifiedUpdateSwap() async throws {
    _ = try await client.restartAfterVerifiedUpdateSwap()
    try await verifyNormalSleep()
  }

  private func verifyNormalSleep() async throws {
    let status = try await client.status()
    guard status.status.state == .inactive, status.observedSleepDisabled == false else {
      throw AppUpdateHelperError.normalSleepNotVerified
    }
  }
}
