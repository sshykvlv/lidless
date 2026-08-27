import AppKit
import LidlessCore
import UserNotifications
import os

enum AppLog {
  static let battery = Logger(subsystem: "lv.ykv.lidless", category: "battery")
  static let helper = Logger(subsystem: "lv.ykv.lidless", category: "helper")
  static let state = Logger(subsystem: "lv.ykv.lidless", category: "state")
  static let update = Logger(subsystem: "lv.ykv.lidless", category: "update")
}

@MainActor
final class DiagnosticRecorder {
  private(set) var latestErrorCodes: [String] = []

  func record(_ code: String) {
    latestErrorCodes.append(String(code.prefix(64)))
    latestErrorCodes = Array(latestErrorCodes.suffix(5))
  }
}

@MainActor
final class AppSafetyNotifier: SafetyNotifying {
  private let recorder: DiagnosticRecorder
  var onEvent: (@MainActor @Sendable () -> Void)?

  init(recorder: DiagnosticRecorder) {
    self.recorder = recorder
  }

  func requestAuthorization() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  func notify(_ event: SafetyCoordinatorEvent) {
    let code: String
    let title: String
    let body: String

    switch event {
    case .cutoff(let reason):
      code = "cutoff.\(reason)"
      title = "Lidless restored normal sleep"
      body =
        reason == .atBatteryFloor
        ? "The configured battery cutoff was reached."
        : "The current power sample was not safe."
      AppLog.battery.notice("Safety cutoff reason=\(String(describing: reason), privacy: .public)")
    case .helperRecoveryPending:
      code = "helper.recovery_pending"
      title = "Lidless safety recovery"
      body = "Lidless will restore normal lid sleep automatically within 30 seconds."
      AppLog.helper.error("Helper recovery pending")
    case .samplingFailed:
      code = "battery.sample_failed"
      title = "Lidless could not read the battery"
      body = "Normal lid sleep is being restored as a precaution."
      AppLog.battery.error("Battery sample failed")
    }

    recorder.record(code)
    postNotification(identifier: code, title: title, body: body)
    onEvent?()
  }

  func restorationFault() {
    recorder.record("helper.restore_fault")
    AppLog.helper.fault("Helper restoration fault")
    postNotification(
      identifier: "helper.restore_fault",
      title: "Lidless needs attention",
      body: "Normal lid sleep could not be verified. Open Lidless for recovery options."
    )
  }

  private func postNotification(identifier: String, title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    )
  }
}

struct DiagnosticSnapshot {
  let appVersion: String
  let helperVersion: String
  let service: HelperServiceAvailability
  let helper: ObservedHelperStatus?
  let sample: PowerSample?
  let floor: Int?
  let errorCodes: [String]

  func render() -> String {
    let helperState = helper.map { String(describing: $0.status.state) } ?? "unavailable"
    let helperFault = helper?.status.fault.map(String.init(describing:)) ?? "none"
    let source = sample.map { String(describing: $0.source) } ?? "unavailable"
    let percentage = sample?.percentage.map(String.init) ?? "unknown"
    let floorValue = floor.map(String.init) ?? "disabled"
    let observed = helper?.observedSleepDisabled.map(String.init) ?? "unknown"
    let errors = errorCodes.isEmpty ? "none" : errorCodes.joined(separator: ",")
    let text = """
      Lidless diagnostics
      app_version=\(appVersion)
      helper_version=\(helperVersion)
      service=\(service.rawValue)
      helper_state=\(helperState)
      helper_fault=\(helperFault)
      power_source=\(source)
      battery_percent=\(percentage)
      battery_floor=\(floorValue)
      sleep_disabled_observed=\(observed)
      recent_errors=\(errors)
      """
    return String(text.prefix(4_096))
  }
}
