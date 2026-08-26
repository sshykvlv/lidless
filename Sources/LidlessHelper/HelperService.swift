import Darwin
import Foundation
import LidlessCore
import os

final class HelperRuntime: @unchecked Sendable {
  private enum TimerPurpose {
    case idle
    case lease
    case recovery
  }

  private static let recoveryDelays: [TimeInterval] = [1, 2, 4, 8, 15]

  private let engine: HelperEngine
  private let legacyGrantMigrator: LegacyGrantMigrator
  private let monotonicClock: any MonotonicClock
  private let buildVersion: String
  private let queue = DispatchQueue(label: "lv.ykv.lidless.helper.runtime")
  private let restartHandler: @Sendable () -> Void
  private let logger = Logger(subsystem: "lv.ykv.lidless.helper", category: "runtime")

  private var recoveryAttempt = 0
  private var timerPurpose = TimerPurpose.idle
  private lazy var timer: DispatchSourceTimer = {
    let source = DispatchSource.makeTimerSource(queue: queue)
    source.setEventHandler { [weak self] in
      self?.timerFired()
    }
    source.schedule(deadline: .distantFuture)
    source.activate()
    return source
  }()

  init(
    engine: HelperEngine,
    buildVersion: String,
    legacyGrantMigrator: LegacyGrantMigrator = LegacyGrantMigrator(),
    monotonicClock: any MonotonicClock = SystemMonotonicClock(),
    restartHandler: @escaping @Sendable () -> Void = { Darwin.exit(EX_TEMPFAIL) }
  ) {
    self.engine = engine
    self.buildVersion = buildVersion
    self.legacyGrantMigrator = legacyGrantMigrator
    self.monotonicClock = monotonicClock
    self.restartHandler = restartHandler
    _ = timer
  }

  func start() {
    queue.sync {
      attemptRecovery()
    }
  }

  func status() -> HelperStatusMessage {
    queue.sync {
      let observed = try? engine.observeSleepDisabled()
      return HelperStatusMessage(
        status: engine.status(),
        observedSleepDisabled: observed,
        buildVersion: buildVersion
      )
    }
  }

  func arm(connectionID: UUID, message: PowerSampleMessage) -> HelperReply {
    queue.sync {
      perform {
        _ = try engine.arm(
          connectionID: connectionID,
          sample: message.sample,
          floor: message.floor
        )
      }
    }
  }

  func renew(connectionID: UUID, sessionID: UUID, message: PowerSampleMessage) -> HelperReply {
    queue.sync {
      perform {
        try engine.renew(
          connectionID: connectionID,
          sessionID: sessionID,
          sample: message.sample,
          floor: message.floor
        )
      }
    }
  }

  func disarm(connectionID: UUID, sessionID: UUID, reason: DisarmReason) -> HelperReply {
    queue.sync {
      perform {
        try engine.disarm(connectionID: connectionID, sessionID: sessionID, reason: reason)
      }
    }
  }

  func connectionInvalidated(connectionID: UUID) {
    queue.async { [self] in
      _ = perform {
        try engine.connectionInvalidated(connectionID: connectionID)
      }
    }
  }

  func restoreNormalSleepAfterConfirmation() -> HelperReply {
    queue.sync {
      perform {
        try engine.restoreNormalSleepAfterConfirmation()
      }
    }
  }

  func verifyRestart() -> HelperReply {
    queue.sync {
      perform {
        try engine.verifyInactiveForRestart()
      }
    }
  }

  func restartAfterReply() {
    queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [restartHandler] in
      restartHandler()
    }
  }

  func removeRecognizedLegacyGrant() -> HelperReply {
    queue.sync {
      do {
        try engine.verifyInactiveForRestart()
        let result = try legacyGrantMigrator.removeRecognizedGrants()
        return makeReply(code: result == .manualCleanupRequired ? .manualCleanupRequired : .ok)
      } catch {
        if error is HelperError {
          return makeReply(code: replyCode(for: error))
        }
        return makeReply(code: .manualCleanupRequired)
      }
    }
  }

  func invalidRequestReply() -> HelperReply {
    queue.sync {
      makeReply(code: .invalidRequest)
    }
  }

  private func perform(_ operation: () throws -> Void) -> HelperReply {
    do {
      try operation()
      recoveryAttempt = 0
      scheduleForCurrentState()
      return makeReply(code: .ok)
    } catch {
      scheduleForCurrentState()
      return makeReply(code: replyCode(for: error))
    }
  }

  private func attemptRecovery() {
    do {
      try engine.recoverAtLaunch()
      recoveryAttempt = 0
      scheduleForCurrentState()
    } catch {
      logger.error("Helper recovery failed: \(String(describing: error), privacy: .public)")
      scheduleRecovery()
    }
  }

  private func timerFired() {
    switch timerPurpose {
    case .idle:
      return
    case .lease:
      do {
        try engine.leaseExpired(now: monotonicClock.now)
        scheduleForCurrentState()
      } catch {
        logger.error("Lease restoration failed: \(String(describing: error), privacy: .public)")
        scheduleForCurrentState()
      }
    case .recovery:
      attemptRecovery()
    }
  }

  private func scheduleForCurrentState() {
    let status = engine.status()
    if status.state == .faulted {
      scheduleRecovery()
    } else if let deadline = engine.nextLeaseDeadline() {
      let delay = max(0, deadline - monotonicClock.now)
      timerPurpose = .lease
      timer.schedule(deadline: .now() + delay, leeway: .milliseconds(100))
    } else {
      timerPurpose = .idle
      timer.schedule(deadline: .distantFuture)
    }
  }

  private func scheduleRecovery() {
    let index = min(recoveryAttempt, Self.recoveryDelays.count - 1)
    let delay = Self.recoveryDelays[index]
    recoveryAttempt = min(recoveryAttempt + 1, Self.recoveryDelays.count - 1)
    timerPurpose = .recovery
    timer.schedule(deadline: .now() + delay, leeway: .milliseconds(100))
  }

  private func makeReply(code: HelperReplyCode) -> HelperReply {
    HelperReply(
      code: code,
      status: HelperStatusMessage(status: engine.status(), buildVersion: buildVersion)
    )
  }

  private func replyCode(for error: Error) -> HelperReplyCode {
    guard let helperError = error as? HelperError else {
      return .faulted
    }
    switch helperError {
    case .externallyDisabled:
      return .externallyDisabled
    case .unsafe:
      return .unsafePower
    case .busy:
      return .busy
    case .faulted:
      return .faulted
    case .wrongConnection:
      return .wrongConnection
    case .wrongSession:
      return .wrongSession
    case .noActiveSession:
      return .noActiveSession
    case .externallyChanged:
      return .externallyChanged
    case .healthCheckFailed:
      return .healthCheckFailed
    case .activationFailed:
      return .activationFailed
    case .restoreFailed:
      return .restoreFailed
    case .corruptJournal:
      return .corruptJournal
    case .recoveryFailed:
      return .recoveryFailed
    }
  }
}

final class HelperSessionService: NSObject, LidlessHelperXPC {
  private let runtime: HelperRuntime
  let connectionID = UUID()

  init(runtime: HelperRuntime) {
    self.runtime = runtime
    super.init()
  }

  func status(reply: @escaping (HelperStatusMessage) -> Void) {
    reply(runtime.status())
  }

  func arm(_ sample: PowerSampleMessage, reply: @escaping (HelperReply) -> Void) {
    reply(runtime.arm(connectionID: connectionID, message: sample))
  }

  func renew(
    sessionID: NSUUID,
    sample: PowerSampleMessage,
    reply: @escaping (HelperReply) -> Void
  ) {
    reply(runtime.renew(connectionID: connectionID, sessionID: sessionID as UUID, message: sample))
  }

  func disarm(sessionID: NSUUID, reason: Int, reply: @escaping (HelperReply) -> Void) {
    guard let reason = DisarmReason(rawValue: reason) else {
      reply(runtime.invalidRequestReply())
      return
    }
    reply(runtime.disarm(connectionID: connectionID, sessionID: sessionID as UUID, reason: reason))
  }

  func removeRecognizedLegacyGrant(reply: @escaping (HelperReply) -> Void) {
    reply(runtime.removeRecognizedLegacyGrant())
  }

  func restoreNormalSleepAfterConfirmation(reply: @escaping (HelperReply) -> Void) {
    reply(runtime.restoreNormalSleepAfterConfirmation())
  }

  func restartAfterVerifiedUpdateSwap(reply: @escaping (HelperReply) -> Void) {
    let result = runtime.verifyRestart()
    reply(result)
    if result.succeeded {
      runtime.restartAfterReply()
    }
  }

}

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
  private let runtime: HelperRuntime

  init(runtime: HelperRuntime) {
    self.runtime = runtime
    super.init()
  }

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    newConnection.setCodeSigningRequirement(CodeSigningRequirements.app)

    let service = HelperSessionService(runtime: runtime)
    let interface = HelperXPCInterfaces.make()
    newConnection.exportedInterface = interface
    newConnection.exportedObject = service
    newConnection.interruptionHandler = { [runtime, connectionID = service.connectionID] in
      runtime.connectionInvalidated(connectionID: connectionID)
    }
    newConnection.invalidationHandler = { [runtime, connectionID = service.connectionID] in
      runtime.connectionInvalidated(connectionID: connectionID)
    }
    newConnection.activate()
    return true
  }

}
