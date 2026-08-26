import Foundation
import XCTest

@testable import LidlessCore

@MainActor
final class SafetyCoordinatorTests: XCTestCase {
  private let sessionID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private var battery: FakeBattery!
  private var helper: FakeHelperClient!
  private var activity: FakeActivityManager!
  private var scheduler: FakeRenewalScheduler!
  private var notifier: FakeSafetyNotifier!
  private var coordinator: SafetyCoordinator!

  override func setUp() async throws {
    try await super.setUp()
    battery = FakeBattery()
    helper = FakeHelperClient(sessionID: sessionID)
    activity = FakeActivityManager()
    scheduler = FakeRenewalScheduler()
    notifier = FakeSafetyNotifier()
    coordinator = SafetyCoordinator(
      powerSampler: battery,
      batteryMonitor: battery,
      helper: helper,
      activity: activity,
      renewalScheduler: scheduler,
      notifier: notifier,
      wallClock: FixedCoordinatorWallClock(now: now)
    )
  }

  func testArmSamplesImmediatelyThenStartsActivityMonitoringAndRenewal() async throws {
    battery.next = sample(.battery, 42)

    try await coordinator.arm(floor: BatteryFloor(10)!)

    XCTAssertEqual(helper.calls, [.arm(sample(.battery, 42), BatteryFloor(10)!)])
    XCTAssertTrue(coordinator.isArmed)
    XCTAssertTrue(activity.isActive)
    XCTAssertTrue(battery.isMonitoring)
    XCTAssertEqual(scheduler.interval, 10)
  }

  func testExactFloorDisarmsWithoutRenewing() async throws {
    try await armAt(11, floor: 10)
    battery.next = sample(.battery, 10)

    await coordinator.powerDidChange()

    XCTAssertEqual(helper.calls.last, .disarm(sessionID, .batteryFloor))
    XCTAssertFalse(coordinator.isArmed)
    XCTAssertFalse(activity.isActive)
    XCTAssertFalse(battery.isMonitoring)
    XCTAssertNil(scheduler.interval)
  }

  func testRenewFailureEndsLocalOwnershipAndNotifies() async throws {
    try await armAt(80, floor: 10)
    helper.renewError = HelperClientError.connectionLost

    await coordinator.renewalFired()

    XCTAssertFalse(coordinator.isArmed)
    XCTAssertFalse(activity.isActive)
    XCTAssertEqual(notifier.events.last, .helperRecoveryPending)
  }

  func testFloorChangeEvaluatesImmediately() async throws {
    try await armAt(15, floor: 10)

    await coordinator.setFloor(BatteryFloor(20)!)

    XCTAssertEqual(helper.calls.last, .disarm(sessionID, .batteryFloor))
    XCTAssertFalse(coordinator.isArmed)
  }

  func testSafePowerChangeRenewsWithFreshSample() async throws {
    try await armAt(50, floor: 10)
    battery.next = sample(.charging, 51)

    await coordinator.powerDidChange()

    XCTAssertEqual(
      helper.calls.last,
      .renew(sessionID, sample(.charging, 51), BatteryFloor(10)!)
    )
    XCTAssertTrue(coordinator.isArmed)
  }

  func testUnsafeInitialSampleNeverContactsHelper() async {
    battery.next = sample(.unknown, nil)

    do {
      try await coordinator.arm(floor: BatteryFloor(10)!)
      XCTFail("Expected unsafe initial sample to be rejected")
    } catch {
      XCTAssertEqual(error as? SafetyCoordinatorError, .unsafe(.unknownPower))
    }

    XCTAssertTrue(helper.calls.isEmpty)
    XCTAssertFalse(activity.isActive)
  }

  func testArmFailureDoesNotStartLocalKeepAliveResources() async {
    battery.next = sample(.battery, 90)
    helper.armError = HelperClientError.connectionLost

    do {
      try await coordinator.arm(floor: BatteryFloor(10)!)
      XCTFail("Expected helper arm failure")
    } catch {
      XCTAssertEqual(error as? HelperClientError, .connectionLost)
    }

    XCTAssertFalse(coordinator.isArmed)
    XCTAssertFalse(activity.isActive)
    XCTAssertFalse(battery.isMonitoring)
    XCTAssertNil(scheduler.interval)
  }

  func testDisarmFailureStillStopsLocallyAndNotifies() async throws {
    try await armAt(80, floor: 10)
    helper.disarmError = HelperClientError.connectionLost

    await coordinator.disarm(reason: .user)

    XCTAssertFalse(coordinator.isArmed)
    XCTAssertFalse(activity.isActive)
    XCTAssertFalse(battery.isMonitoring)
    XCTAssertEqual(notifier.events.last, .helperRecoveryPending)
  }

  func testCancelledArmFailureCannotStopAReplacementSession() async throws {
    battery.next = sample(.battery, 80)
    helper.suspendNextArm = true
    let firstArm = Task { @MainActor [coordinator] in
      try? await coordinator?.arm(floor: BatteryFloor(10)!)
    }
    await Task.yield()
    XCTAssertTrue(helper.hasPendingArm)

    await coordinator.disarm(reason: .user)
    try await coordinator.arm(floor: BatteryFloor(10)!)
    XCTAssertTrue(activity.isActive)

    helper.failPendingArm()
    _ = await firstArm.result

    XCTAssertTrue(coordinator.isArmed)
    XCTAssertTrue(activity.isActive)
    XCTAssertTrue(battery.isMonitoring)
    XCTAssertEqual(scheduler.interval, 10)
  }

  private func armAt(_ percentage: Int, floor: Int) async throws {
    battery.next = sample(.battery, percentage)
    try await coordinator.arm(floor: BatteryFloor(floor)!)
  }

  private func sample(_ source: PowerSource, _ percentage: Int?) -> PowerSample {
    PowerSample(source: source, percentage: percentage, sampledAt: now)
  }
}

@MainActor
private final class FakeBattery: PowerSampling, BatteryMonitoring {
  var next = PowerSample(source: .unknown, percentage: nil, sampledAt: .distantPast)
  var sampleError: Error?
  private(set) var isMonitoring = false
  private var handler: (@MainActor @Sendable () -> Void)?

  func sample() throws -> PowerSample {
    if let sampleError {
      throw sampleError
    }
    return next
  }

  func start(_ handler: @escaping @MainActor @Sendable () -> Void) {
    isMonitoring = true
    self.handler = handler
  }

  func stop() {
    isMonitoring = false
    handler = nil
  }
}

private enum HelperCall: Equatable {
  case arm(PowerSample, BatteryFloor)
  case renew(UUID, PowerSample, BatteryFloor)
  case disarm(UUID, DisarmReason)
}

@MainActor
private final class FakeHelperClient: HelperControllingClient {
  let sessionID: UUID
  var armError: Error?
  var renewError: Error?
  var disarmError: Error?
  var suspendNextArm = false
  private var pendingArm: CheckedContinuation<HelperStatus, any Error>?
  private(set) var calls: [HelperCall] = []

  var hasPendingArm: Bool { pendingArm != nil }

  init(sessionID: UUID) {
    self.sessionID = sessionID
  }

  func arm(sample: PowerSample, floor: BatteryFloor) async throws -> HelperStatus {
    calls.append(.arm(sample, floor))
    if let armError {
      throw armError
    }
    if suspendNextArm {
      suspendNextArm = false
      return try await withCheckedThrowingContinuation { continuation in
        pendingArm = continuation
      }
    }
    return HelperStatus(
      state: .active,
      sessionID: sessionID,
      leaseDeadline: 130,
      lastDisarmReason: nil,
      fault: nil
    )
  }

  func renew(sessionID: UUID, sample: PowerSample, floor: BatteryFloor) async throws
    -> HelperStatus
  {
    calls.append(.renew(sessionID, sample, floor))
    if let renewError {
      throw renewError
    }
    return HelperStatus(
      state: .active,
      sessionID: sessionID,
      leaseDeadline: 140,
      lastDisarmReason: nil,
      fault: nil
    )
  }

  func disarm(sessionID: UUID, reason: DisarmReason) async throws -> HelperStatus {
    calls.append(.disarm(sessionID, reason))
    if let disarmError {
      throw disarmError
    }
    return HelperStatus(
      state: .inactive,
      sessionID: nil,
      leaseDeadline: nil,
      lastDisarmReason: reason,
      fault: nil
    )
  }

  func failPendingArm() {
    let continuation = pendingArm
    pendingArm = nil
    continuation?.resume(throwing: HelperClientError.connectionLost)
  }
}

@MainActor
private final class FakeActivityManager: ActivityManaging {
  private(set) var isActive = false

  func begin() {
    isActive = true
  }

  func end() {
    isActive = false
  }
}

@MainActor
private final class FakeRenewalScheduler: RenewalScheduling {
  private(set) var interval: TimeInterval?
  private var handler: (@MainActor @Sendable () -> Void)?

  func start(interval: TimeInterval, handler: @escaping @MainActor @Sendable () -> Void) {
    self.interval = interval
    self.handler = handler
  }

  func stop() {
    interval = nil
    handler = nil
  }
}

@MainActor
private final class FakeSafetyNotifier: SafetyNotifying {
  private(set) var events: [SafetyCoordinatorEvent] = []

  func notify(_ event: SafetyCoordinatorEvent) {
    events.append(event)
  }
}

private final class FixedCoordinatorWallClock: WallClock {
  let now: Date

  init(now: Date) {
    self.now = now
  }
}
