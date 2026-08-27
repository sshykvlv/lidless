import Foundation

public enum HelperClientError: Error, Equatable, Sendable {
  case connectionLost
  case invalidResponse
  case helper(HelperReplyCode)
}

public enum SafetyCoordinatorError: Error, Equatable, Sendable {
  case alreadyArmed
  case unsafe(CutoffReason)
  case invalidHelperStatus
}

public enum SafetyCoordinatorEvent: Equatable, Sendable {
  case helperRecoveryPending
  case cutoff(CutoffReason)
  case samplingFailed
}

@MainActor
public protocol PowerSampling: AnyObject {
  func sample() throws -> PowerSample
}

@MainActor
public protocol BatteryMonitoring: AnyObject {
  func start(_ handler: @escaping @MainActor @Sendable () -> Void)
  func stop()
}

@MainActor
public protocol HelperControllingClient: AnyObject {
  func arm(sample: PowerSample, floor: BatteryFloor) async throws -> HelperStatus
  func renew(sessionID: UUID, sample: PowerSample, floor: BatteryFloor) async throws -> HelperStatus
  func disarm(sessionID: UUID, reason: DisarmReason) async throws -> HelperStatus
}

@MainActor
public protocol ActivityManaging: AnyObject {
  func begin()
  func end()
}

@MainActor
public protocol RenewalScheduling: AnyObject {
  func start(interval: TimeInterval, handler: @escaping @MainActor @Sendable () -> Void)
  func stop()
}

@MainActor
public protocol SafetyNotifying: AnyObject {
  func notify(_ event: SafetyCoordinatorEvent)
}

@MainActor
public final class SafetyCoordinator {
  public static let renewalInterval: TimeInterval = 10

  private enum State: Equatable {
    case idle
    case arming(UUID)
    case armed(sessionID: UUID, floor: BatteryFloor)
  }

  private let powerSampler: any PowerSampling
  private let batteryMonitor: any BatteryMonitoring
  private let helper: any HelperControllingClient
  private let activity: any ActivityManaging
  private let renewalScheduler: any RenewalScheduling
  private let notifier: any SafetyNotifying
  private let wallClock: any WallClock

  private var state = State.idle
  private var evaluationInFlight = false
  private var evaluationPending = false

  public var isArmed: Bool {
    if case .armed = state {
      return true
    }
    return false
  }

  public init(
    powerSampler: any PowerSampling,
    batteryMonitor: any BatteryMonitoring,
    helper: any HelperControllingClient,
    activity: any ActivityManaging,
    renewalScheduler: any RenewalScheduling,
    notifier: any SafetyNotifying,
    wallClock: any WallClock = SystemWallClock()
  ) {
    self.powerSampler = powerSampler
    self.batteryMonitor = batteryMonitor
    self.helper = helper
    self.activity = activity
    self.renewalScheduler = renewalScheduler
    self.notifier = notifier
    self.wallClock = wallClock
  }

  public func arm(floor: BatteryFloor) async throws {
    guard state == .idle else {
      throw SafetyCoordinatorError.alreadyArmed
    }

    let sample = try powerSampler.sample()
    if case .cutoff(let reason) = SafetyPolicy.evaluate(
      sample: sample,
      floor: floor,
      now: wallClock.now
    ) {
      throw SafetyCoordinatorError.unsafe(reason)
    }

    let operationID = UUID()
    state = .arming(operationID)

    let status: HelperStatus
    do {
      status = try await helper.arm(sample: sample, floor: floor)
    } catch {
      if state == .arming(operationID) {
        state = .idle
        stopLocalResources()
      }
      throw error
    }

    guard status.state == .active, let sessionID = status.sessionID else {
      if state == .arming(operationID) {
        state = .idle
        stopLocalResources()
      }
      notifier.notify(.helperRecoveryPending)
      throw SafetyCoordinatorError.invalidHelperStatus
    }

    guard state == .arming(operationID) else {
      _ = try? await helper.disarm(sessionID: sessionID, reason: .user)
      throw SafetyCoordinatorError.invalidHelperStatus
    }

    state = .armed(sessionID: sessionID, floor: floor)
    activity.begin()
    batteryMonitor.start { [weak self] in
      Task { @MainActor [weak self] in
        await self?.powerDidChange()
      }
    }
    renewalScheduler.start(interval: Self.renewalInterval) { [weak self] in
      Task { @MainActor [weak self] in
        await self?.renewalFired()
      }
    }
  }

  public func powerDidChange() async {
    await evaluateFreshSampleAndRenew()
  }

  public func renewalFired() async {
    await evaluateFreshSampleAndRenew()
  }

  public func setFloor(_ floor: BatteryFloor) async {
    guard case .armed(let sessionID, _) = state else {
      return
    }
    state = .armed(sessionID: sessionID, floor: floor)
    await evaluateFreshSampleAndRenew()
  }

  public func disarm(reason: DisarmReason) async {
    switch state {
    case .idle:
      return
    case .arming:
      state = .idle
      stopLocalResources()
    case .armed(let sessionID, _):
      state = .idle
      stopLocalResources()
      do {
        _ = try await helper.disarm(sessionID: sessionID, reason: reason)
      } catch {
        notifier.notify(.helperRecoveryPending)
      }
    }
  }

  public func helperConnectionLost() {
    guard state != .idle else {
      return
    }
    state = .idle
    stopLocalResources()
    notifier.notify(.helperRecoveryPending)
  }

  private func evaluateFreshSampleAndRenew() async {
    guard isArmed else {
      return
    }
    if evaluationInFlight {
      evaluationPending = true
      return
    }

    evaluationInFlight = true
    repeat {
      evaluationPending = false
      await performOneEvaluation()
    } while evaluationPending && isArmed
    evaluationInFlight = false
  }

  private func performOneEvaluation() async {
    guard case .armed(let sessionID, let floor) = state else {
      return
    }

    let sample: PowerSample
    do {
      sample = try powerSampler.sample()
    } catch {
      notifier.notify(.samplingFailed)
      await endOwnedSession(sessionID: sessionID, reason: .unsafePower, cutoff: nil)
      return
    }

    switch SafetyPolicy.evaluate(sample: sample, floor: floor, now: wallClock.now) {
    case .allow:
      do {
        let status = try await helper.renew(sessionID: sessionID, sample: sample, floor: floor)
        guard case .armed(let currentSessionID, _) = state,
          currentSessionID == sessionID
        else {
          return
        }
        guard status.state == .active, status.sessionID == sessionID else {
          state = .idle
          stopLocalResources()
          notifier.notify(.helperRecoveryPending)
          return
        }
      } catch {
        guard case .armed(let currentSessionID, _) = state,
          currentSessionID == sessionID
        else {
          return
        }
        state = .idle
        stopLocalResources()
        notifier.notify(.helperRecoveryPending)
      }

    case .cutoff(let reason):
      let disarmReason: DisarmReason = reason == .atBatteryFloor ? .batteryFloor : .unsafePower
      await endOwnedSession(sessionID: sessionID, reason: disarmReason, cutoff: reason)
    }
  }

  private func endOwnedSession(
    sessionID: UUID,
    reason: DisarmReason,
    cutoff: CutoffReason?
  ) async {
    guard case .armed(let currentSessionID, _) = state,
      currentSessionID == sessionID
    else {
      return
    }

    state = .idle
    stopLocalResources()
    if let cutoff {
      notifier.notify(.cutoff(cutoff))
    }
    do {
      _ = try await helper.disarm(sessionID: sessionID, reason: reason)
    } catch {
      notifier.notify(.helperRecoveryPending)
    }
  }

  private func stopLocalResources() {
    renewalScheduler.stop()
    batteryMonitor.stop()
    activity.end()
  }
}
