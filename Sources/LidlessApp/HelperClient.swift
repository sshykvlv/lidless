import Foundation
import LidlessCore

struct ObservedHelperStatus: Equatable, Sendable {
  let status: HelperStatus
  let observedSleepDisabled: Bool?
}

enum LegacyCleanupDisposition: Equatable, Sendable {
  case complete
  case manualCleanupRequired
}

@MainActor
final class XPCScheduledHelperClient: HelperControllingClient {
  private static let callTimeout: TimeInterval = 5

  private let connection: NSXPCConnection
  var onInvalidation: (@MainActor @Sendable () -> Void)?

  init() {
    let connection = NSXPCConnection(
      machServiceName: "lv.ykv.lidless.helper",
      options: .privileged
    )
    connection.setCodeSigningRequirement(CodeSigningRequirements.helper)
    connection.remoteObjectInterface = HelperXPCInterfaces.make()
    self.connection = connection

    connection.invalidationHandler = { [weak self] in
      Task { @MainActor [weak self] in
        self?.onInvalidation?()
      }
    }
    connection.interruptionHandler = { [weak self] in
      Task { @MainActor [weak self] in
        self?.onInvalidation?()
      }
    }
    connection.activate()
  }

  isolated deinit {
    connection.invalidate()
  }

  func arm(sample: PowerSample, floor: BatteryFloor) async throws -> HelperStatus {
    let message = PowerSampleMessage(
      source: sample.source,
      percentage: sample.percentage,
      sampledAt: sample.sampledAt,
      floor: floor.percentage
    )
    return try await perform { proxy, reply in
      proxy.arm(message, reply: reply)
    }
  }

  func renew(sessionID: UUID, sample: PowerSample, floor: BatteryFloor) async throws
    -> HelperStatus
  {
    let message = PowerSampleMessage(
      source: sample.source,
      percentage: sample.percentage,
      sampledAt: sample.sampledAt,
      floor: floor.percentage
    )
    return try await perform { proxy, reply in
      proxy.renew(sessionID: sessionID as NSUUID, sample: message, reply: reply)
    }
  }

  func disarm(sessionID: UUID, reason: DisarmReason) async throws -> HelperStatus {
    try await perform { proxy, reply in
      proxy.disarm(sessionID: sessionID as NSUUID, reason: reason.rawValue, reply: reply)
    }
  }

  func status() async throws -> ObservedHelperStatus {
    try await withCheckedThrowingContinuation { continuation in
      let gate = HelperStatusGate(continuation: continuation)
      scheduleTimeout(for: gate)
      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
          gate.fail(HelperClientError.connectionLost)
        }) as? LidlessHelperXPC
      else {
        gate.fail(HelperClientError.connectionLost)
        return
      }
      proxy.status { message in
        gate.receive(message)
      }
    }
  }

  func removeRecognizedLegacyGrant() async throws -> LegacyCleanupDisposition {
    let response = try await performResponse { proxy, reply in
      proxy.removeRecognizedLegacyGrant(reply: reply)
    }
    switch response.code {
    case .ok:
      return .complete
    case .manualCleanupRequired:
      return .manualCleanupRequired
    default:
      throw HelperClientError.helper(response.code)
    }
  }

  func restoreNormalSleepAfterConfirmation() async throws -> HelperStatus {
    try await perform { proxy, reply in
      proxy.restoreNormalSleepAfterConfirmation(reply: reply)
    }
  }

  func restartAfterVerifiedUpdateSwap() async throws -> HelperStatus {
    try await perform { proxy, reply in
      proxy.restartAfterVerifiedUpdateSwap(reply: reply)
    }
  }

  private func perform(
    _ invoke: (LidlessHelperXPC, @escaping (HelperReply) -> Void) -> Void
  ) async throws -> HelperStatus {
    let response = try await performResponse(invoke)
    guard response.code == .ok else {
      throw HelperClientError.helper(response.code)
    }
    return response.status
  }

  private func performResponse(
    _ invoke: (LidlessHelperXPC, @escaping (HelperReply) -> Void) -> Void
  ) async throws -> HelperOperationResponse {
    try await withCheckedThrowingContinuation { continuation in
      let gate = HelperReplyGate(continuation: continuation)
      scheduleTimeout(for: gate)
      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
          gate.fail(HelperClientError.connectionLost)
        }) as? LidlessHelperXPC
      else {
        gate.fail(HelperClientError.connectionLost)
        return
      }
      invoke(proxy) { reply in
        gate.receive(reply)
      }
    }
  }

  private func scheduleTimeout(for gate: some XPCReplyFailing & Sendable) {
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.callTimeout) {
      gate.fail(HelperClientError.connectionLost)
    }
  }
}

private protocol XPCReplyFailing: AnyObject {
  func fail(_ error: any Error)
}

private struct HelperOperationResponse: Sendable {
  let code: HelperReplyCode
  let status: HelperStatus
}

private final class HelperReplyGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<HelperOperationResponse, any Error>?

  init(continuation: CheckedContinuation<HelperOperationResponse, any Error>) {
    self.continuation = continuation
  }

  func receive(_ reply: HelperReply) {
    finish(
      .success(
        HelperOperationResponse(
          code: reply.code,
          status: reply.status.status
        )))
  }

  func fail(_ error: any Error) {
    finish(.failure(error))
  }

  private func finish(_ result: Result<HelperOperationResponse, any Error>) {
    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(with: result)
  }
}

extension HelperReplyGate: XPCReplyFailing {}

private final class HelperStatusGate: @unchecked Sendable, XPCReplyFailing {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<ObservedHelperStatus, any Error>?

  init(continuation: CheckedContinuation<ObservedHelperStatus, any Error>) {
    self.continuation = continuation
  }

  func receive(_ message: HelperStatusMessage) {
    finish(
      .success(
        ObservedHelperStatus(
          status: message.status,
          observedSleepDisabled: message.observedSleepDisabled
        )))
  }

  func fail(_ error: any Error) {
    finish(.failure(error))
  }

  private func finish(_ result: Result<ObservedHelperStatus, any Error>) {
    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(with: result)
  }
}
