import LidlessCore

struct ObservedHelperStatus: Equatable, Sendable {
  let status: HelperStatus
  let observedSleepDisabled: Bool?
  let buildVersion: String
}

enum HelperServiceAvailability: String, Sendable {
  case notRegistered
  case enabled
  case approvalRequired
  case notFound
}

enum MenuHelperFaultCode: String, Equatable, Sendable {
  case connection
  case corruptJournal
  case restoreFailed
  case activationFailed
  case unexpectedJournal
  case unknown
}

enum MenuSafetyState: Equatable, Sendable {
  case off
  case armed(percent: Int?, onBattery: Bool)
  case externalKeepAwake
  case unverified
  case helperNotRegistered
  case helperApprovalRequired
  case restoring
  case fault(code: MenuHelperFaultCode)
}

enum MenuStateResolver {
  static func resolve(
    service: HelperServiceAvailability,
    helper: ObservedHelperStatus?,
    sample: PowerSample?
  ) -> MenuSafetyState {
    switch service {
    case .notRegistered, .notFound:
      return .helperNotRegistered
    case .approvalRequired:
      return .helperApprovalRequired
    case .enabled:
      break
    }

    guard let helper else {
      return .fault(code: .connection)
    }
    switch helper.status.state {
    case .inactive:
      guard let sleepDisabled = helper.observedSleepDisabled else {
        return .unverified
      }
      return sleepDisabled ? .externalKeepAwake : .off
    case .activating, .restoring:
      return .restoring
    case .active:
      return .armed(
        percent: sample?.percentage,
        onBattery: sample?.source == .battery
      )
    case .faulted:
      return .fault(code: faultCode(helper.status.fault))
    }
  }

  private static func faultCode(_ fault: HelperFault?) -> MenuHelperFaultCode {
    switch fault {
    case .corruptJournal:
      return .corruptJournal
    case .restoreFailed:
      return .restoreFailed
    case .activationFailed:
      return .activationFailed
    case .unexpectedJournal:
      return .unexpectedJournal
    case nil:
      return .unknown
    }
  }
}
