import Foundation
import LidlessCore

@MainActor
final class XPCScheduledHelperClient: HelperControllingClient {
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

  private func perform(
    _ invoke: (LidlessHelperXPC, @escaping (HelperReply) -> Void) -> Void
  ) async throws -> HelperStatus {
    try await withCheckedThrowingContinuation { continuation in
      let gate = HelperReplyGate(continuation: continuation)
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
}

private final class HelperReplyGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<HelperStatus, any Error>?

  init(continuation: CheckedContinuation<HelperStatus, any Error>) {
    self.continuation = continuation
  }

  func receive(_ reply: HelperReply) {
    if reply.succeeded {
      finish(.success(reply.status.status))
    } else {
      finish(.failure(HelperClientError.helper(reply.code)))
    }
  }

  func fail(_ error: any Error) {
    finish(.failure(error))
  }

  private func finish(_ result: Result<HelperStatus, any Error>) {
    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(with: result)
  }
}
