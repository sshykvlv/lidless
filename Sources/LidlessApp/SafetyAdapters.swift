import Foundation
import LidlessCore

@MainActor
final class ProcessActivityManager: ActivityManaging {
  private var token: NSObjectProtocol?

  func begin() {
    guard token == nil else {
      return
    }
    token = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep,
      reason: "Lidless safety lease"
    )
  }

  func end() {
    guard let token else {
      return
    }
    ProcessInfo.processInfo.endActivity(token)
    self.token = nil
  }

  isolated deinit {
    if let token {
      ProcessInfo.processInfo.endActivity(token)
    }
  }
}

@MainActor
final class CommonModeRenewalScheduler: RenewalScheduling {
  private var timer: Timer?

  func start(interval: TimeInterval, handler: @escaping @MainActor @Sendable () -> Void) {
    stop()
    let timer = Timer(timeInterval: interval, repeats: true) { _ in
      Task { @MainActor in
        handler()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  isolated deinit {
    timer?.invalidate()
  }
}
