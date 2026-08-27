import LidlessCore
import ServiceManagement

struct UninstallOutcome: Sendable {
  let helper: String
  let sleep: String
  let legacy: String
  let succeeded: Bool

  var renderedLine: String {
    "LIDLESS_UNINSTALL helper=\(helper) sleep=\(sleep) legacy=\(legacy) status=\(succeeded ? "ok" : "partial")"
  }
}

@MainActor
final class UninstallCoordinator {
  private let client: XPCScheduledHelperClient
  private let service: SMAppService

  init(client: XPCScheduledHelperClient, service: SMAppService) {
    self.client = client
    self.service = service
  }

  func run(activeCoordinator: SafetyCoordinator?) async -> UninstallOutcome {
    if let activeCoordinator, activeCoordinator.isArmed {
      await activeCoordinator.disarm(reason: .user)
    }

    guard service.status == .enabled else {
      if service.status == .requiresApproval {
        try? await service.unregister()
      }
      return UninstallOutcome(
        helper: service.status == .notRegistered ? "not_registered" : "unavailable",
        sleep: "unverified",
        legacy: "manual",
        succeeded: false
      )
    }

    do {
      let before = try await client.status()
      guard before.status.state == .inactive else {
        return UninstallOutcome(
          helper: "active",
          sleep: "lease_pending",
          legacy: "pending",
          succeeded: false
        )
      }

      _ = try await client.restoreNormalSleepAfterConfirmation()
      let verified = try await client.status()
      guard verified.status.state == .inactive,
        verified.observedSleepDisabled == false
      else {
        return UninstallOutcome(
          helper: "enabled",
          sleep: "unverified",
          legacy: "pending",
          succeeded: false
        )
      }

      let cleanup = try await client.removeRecognizedLegacyGrant()
      try await service.unregister()
      return UninstallOutcome(
        helper: "removed",
        sleep: "normal",
        legacy: cleanup == .complete ? "complete" : "manual",
        succeeded: cleanup == .complete
      )
    } catch {
      return UninstallOutcome(
        helper: "error",
        sleep: "unverified",
        legacy: "pending",
        succeeded: false
      )
    }
  }
}
