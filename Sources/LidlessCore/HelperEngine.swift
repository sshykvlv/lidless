import Foundation

public protocol WallClock: AnyObject {
  var now: Date { get }
}

public protocol MonotonicClock: AnyObject {
  var now: TimeInterval { get }
}

public final class SystemWallClock: WallClock {
  public init() {}
  public var now: Date { Date() }
}

public final class SystemMonotonicClock: MonotonicClock {
  public init() {}
  public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

public enum HelperState: Int, Equatable, Sendable {
  case inactive
  case activating
  case active
  case restoring
  case faulted
}

public enum DisarmReason: Int, Equatable, Sendable {
  case user
  case batteryFloor
  case unsafePower
  case connectionInvalidated
  case leaseExpired
  case externalChange
  case recovery
  case activationFailure
  case appQuit
}

public enum HelperFault: Int, Equatable, Sendable {
  case corruptJournal
  case restoreFailed
  case activationFailed
  case unexpectedJournal
}

public struct HelperStatus: Equatable, Sendable {
  public let state: HelperState
  public let sessionID: UUID?
  public let leaseDeadline: TimeInterval?
  public let lastDisarmReason: DisarmReason?
  public let fault: HelperFault?

  public init(
    state: HelperState,
    sessionID: UUID?,
    leaseDeadline: TimeInterval?,
    lastDisarmReason: DisarmReason?,
    fault: HelperFault?
  ) {
    self.state = state
    self.sessionID = sessionID
    self.leaseDeadline = leaseDeadline
    self.lastDisarmReason = lastDisarmReason
    self.fault = fault
  }
}

public enum HelperError: Error, Equatable, Sendable {
  case externallyDisabled
  case unsafe(CutoffReason)
  case busy
  case faulted
  case wrongConnection
  case wrongSession
  case noActiveSession
  case externallyChanged
  case healthCheckFailed
  case activationFailed
  case restoreFailed
  case corruptJournal
  case recoveryFailed
}

public final class HelperEngine: @unchecked Sendable {
  public static let leaseDuration: TimeInterval = 30

  private struct Ownership {
    var journal: HelperJournal
    var leaseDeadline: TimeInterval?
  }

  private struct OwnershipIdentity: Equatable {
    let connectionID: UUID
    let sessionID: UUID
  }

  private let pmset: any PMSetControlling
  private let journalStore: any JournalStoring
  private let wallClock: any WallClock
  private let monotonicClock: any MonotonicClock
  private let queue = DispatchQueue(label: "lv.ykv.lidless.helper.engine")

  private var state: HelperState = .inactive
  private var ownership: Ownership?
  private var lastCompletedOwnership: OwnershipIdentity?
  private var lastDisarmReason: DisarmReason?
  private var fault: HelperFault?

  public init(
    pmset: any PMSetControlling,
    journal: any JournalStoring,
    wallClock: any WallClock = SystemWallClock(),
    monotonicClock: any MonotonicClock = SystemMonotonicClock()
  ) {
    self.pmset = pmset
    journalStore = journal
    self.wallClock = wallClock
    self.monotonicClock = monotonicClock
  }

  public func recoverAtLaunch() throws {
    try queue.sync {
      let persisted: HelperJournal
      do {
        guard let loaded = try journalStore.load() else {
          ownership = nil
          state = .inactive
          fault = nil
          return
        }
        persisted = loaded
      } catch {
        try failSafeCorruptJournal()
      }

      guard persisted.originalSleepDisabled == false else {
        try failSafeCorruptJournal()
      }
      ownership = Ownership(journal: persisted, leaseDeadline: nil)
      try restoreOwnedSession(reason: .recovery)
    }
  }

  public func status() -> HelperStatus {
    queue.sync {
      HelperStatus(
        state: state,
        sessionID: ownership?.journal.sessionID,
        leaseDeadline: ownership?.leaseDeadline,
        lastDisarmReason: lastDisarmReason,
        fault: fault
      )
    }
  }

  public func observeSleepDisabled() throws -> Bool {
    try queue.sync {
      let observed = try pmset.readSleepDisabled()
      if state == .active, observed == false {
        try finishExternalOwnershipLoss()
      }
      return observed
    }
  }

  public func arm(connectionID: UUID, sample: PowerSample, floor: BatteryFloor) throws -> UUID {
    try queue.sync {
      switch state {
      case .inactive:
        break
      case .faulted:
        throw HelperError.faulted
      case .activating, .active, .restoring:
        throw HelperError.busy
      }

      if case .cutoff(let reason) = SafetyPolicy.evaluate(
        sample: sample, floor: floor, now: wallClock.now)
      {
        throw HelperError.unsafe(reason)
      }

      do {
        if try journalStore.load() != nil {
          state = .faulted
          fault = .unexpectedJournal
          throw HelperError.faulted
        }
      } catch let error as HelperError {
        throw error
      } catch {
        try failSafeCorruptJournal()
      }

      let observed: Bool
      do {
        observed = try pmset.readSleepDisabled()
      } catch {
        throw HelperError.activationFailed
      }
      guard observed == false else {
        throw HelperError.externallyDisabled
      }

      let sessionID = UUID()
      let activatingJournal = HelperJournal(
        sessionID: sessionID,
        connectionID: connectionID,
        originalSleepDisabled: observed,
        phase: .activating,
        armedAt: wallClock.now
      )
      state = .activating

      do {
        try journalStore.save(activatingJournal)
        ownership = Ownership(journal: activatingJournal, leaseDeadline: nil)
        try pmset.setSleepDisabled(true)
        guard try pmset.readSleepDisabled() == true else {
          throw HelperError.activationFailed
        }

        var activeJournal = activatingJournal
        activeJournal.phase = .active
        try journalStore.save(activeJournal)
        ownership = Ownership(
          journal: activeJournal,
          leaseDeadline: monotonicClock.now + Self.leaseDuration
        )
        state = .active
        fault = nil
        lastDisarmReason = nil
        return sessionID
      } catch {
        fault = .activationFailed
        if ownership != nil {
          do {
            try restoreOwnedSession(reason: .activationFailure)
          } catch {
            throw HelperError.restoreFailed
          }
        } else {
          state = .inactive
        }
        throw HelperError.activationFailed
      }
    }
  }

  public func renew(
    connectionID: UUID,
    sessionID: UUID,
    sample: PowerSample,
    floor: BatteryFloor
  ) throws {
    try queue.sync {
      try requireActiveOwnership(connectionID: connectionID, sessionID: sessionID)

      let observed: Bool
      do {
        observed = try pmset.readSleepDisabled()
      } catch {
        try restoreOwnedSession(reason: .unsafePower)
        throw HelperError.healthCheckFailed
      }
      if observed == false {
        try finishExternalOwnershipLoss()
        throw HelperError.externallyChanged
      }

      if case .cutoff(let reason) = SafetyPolicy.evaluate(
        sample: sample, floor: floor, now: wallClock.now)
      {
        let disarmReason: DisarmReason = reason == .atBatteryFloor ? .batteryFloor : .unsafePower
        try restoreOwnedSession(reason: disarmReason)
        throw HelperError.unsafe(reason)
      }

      ownership?.leaseDeadline = monotonicClock.now + Self.leaseDuration
    }
  }

  public func disarm(connectionID: UUID, sessionID: UUID, reason: DisarmReason) throws {
    try queue.sync {
      if state == .inactive {
        if lastCompletedOwnership
          == OwnershipIdentity(connectionID: connectionID, sessionID: sessionID)
        {
          return
        }
        throw HelperError.noActiveSession
      }
      try requireActiveOwnership(connectionID: connectionID, sessionID: sessionID)
      try restoreOwnedSession(reason: reason)
    }
  }

  public func connectionInvalidated(connectionID: UUID) throws {
    try queue.sync {
      guard state == .active,
        ownership?.journal.connectionID == connectionID
      else {
        return
      }
      try restoreOwnedSession(reason: .connectionInvalidated)
    }
  }

  public func leaseExpired(now: TimeInterval) throws {
    try queue.sync {
      guard state == .active,
        let deadline = ownership?.leaseDeadline,
        now >= deadline
      else {
        return
      }
      try restoreOwnedSession(reason: .leaseExpired)
    }
  }

  public func nextLeaseDeadline() -> TimeInterval? {
    queue.sync {
      guard state == .active else {
        return nil
      }
      return ownership?.leaseDeadline
    }
  }

  public func restoreNormalSleepAfterConfirmation() throws {
    try queue.sync {
      guard state == .inactive else {
        throw state == .faulted ? HelperError.faulted : HelperError.busy
      }
      guard try journalStore.load() == nil else {
        state = .faulted
        fault = .unexpectedJournal
        throw HelperError.faulted
      }
      do {
        try pmset.setSleepDisabled(false)
        guard try pmset.readSleepDisabled() == false else {
          throw HelperError.restoreFailed
        }
      } catch {
        throw HelperError.restoreFailed
      }
    }
  }

  public func verifyInactiveForRestart() throws {
    try queue.sync {
      guard state == .inactive else {
        throw state == .faulted ? HelperError.faulted : HelperError.busy
      }
      guard try journalStore.load() == nil,
        try pmset.readSleepDisabled() == false
      else {
        throw HelperError.busy
      }
    }
  }

  private func requireActiveOwnership(connectionID: UUID, sessionID: UUID) throws {
    guard state == .active, let ownership else {
      throw state == .faulted ? HelperError.faulted : HelperError.noActiveSession
    }
    guard ownership.journal.connectionID == connectionID else {
      throw HelperError.wrongConnection
    }
    guard ownership.journal.sessionID == sessionID else {
      throw HelperError.wrongSession
    }
  }

  private func restoreOwnedSession(reason: DisarmReason) throws {
    guard var current = ownership else {
      throw HelperError.noActiveSession
    }
    state = .restoring
    current.journal.phase = .restoring

    do {
      try journalStore.save(current.journal)
      ownership = current
      try pmset.setSleepDisabled(current.journal.originalSleepDisabled)
      let observed = try pmset.readSleepDisabled()
      guard observed == current.journal.originalSleepDisabled else {
        throw HelperError.restoreFailed
      }
      try journalStore.clear()
    } catch {
      ownership = current
      state = .faulted
      fault = .restoreFailed
      throw HelperError.restoreFailed
    }

    lastCompletedOwnership = OwnershipIdentity(
      connectionID: current.journal.connectionID,
      sessionID: current.journal.sessionID
    )
    ownership = nil
    state = .inactive
    lastDisarmReason = reason
    fault = nil
  }

  private func finishExternalOwnershipLoss() throws {
    guard var current = ownership else {
      throw HelperError.noActiveSession
    }
    current.journal.phase = .externallyChanged
    do {
      try journalStore.save(current.journal)
      try journalStore.clear()
    } catch {
      ownership = current
      state = .faulted
      fault = .restoreFailed
      throw HelperError.restoreFailed
    }

    lastCompletedOwnership = OwnershipIdentity(
      connectionID: current.journal.connectionID,
      sessionID: current.journal.sessionID
    )
    ownership = nil
    state = .inactive
    lastDisarmReason = .externalChange
    fault = nil
  }

  private func failSafeCorruptJournal() throws -> Never {
    ownership = nil
    state = .faulted
    fault = .corruptJournal
    do {
      try pmset.setSleepDisabled(false)
      guard try pmset.readSleepDisabled() == false else {
        throw HelperError.recoveryFailed
      }
    } catch {
      throw HelperError.recoveryFailed
    }
    throw HelperError.corruptJournal
  }
}
