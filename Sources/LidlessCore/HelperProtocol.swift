import Foundation

public enum HelperProtocolError: Error, Equatable, Sendable {
  case unsupportedVersion(Int)
  case invalidPowerSource(Int)
  case invalidPercentage(Int)
  case invalidSampleDate
  case invalidBatteryFloor(Int)
}

@objc(LidlessPowerSampleMessage)
public final class PowerSampleMessage: NSObject, NSSecureCoding {
  public static let supportsSecureCoding = true
  public static let currentProtocolVersion = 1

  public let protocolVersion: Int
  public let sample: PowerSample
  public let floor: BatteryFloor

  public convenience init(
    source: PowerSource,
    percentage: Int?,
    sampledAt: Date,
    floor: Int?
  ) {
    do {
      try self.init(
        validatingVersion: Self.currentProtocolVersion,
        sourceRaw: source.rawValue,
        percentage: percentage,
        sampledAt: sampledAt,
        floor: floor
      )
    } catch {
      preconditionFailure("Invalid local power sample: \(error)")
    }
  }

  public init(
    validatingVersion version: Int,
    sourceRaw: Int,
    percentage: Int?,
    sampledAt: Date,
    floor: Int?
  ) throws {
    guard version == Self.currentProtocolVersion else {
      throw HelperProtocolError.unsupportedVersion(version)
    }
    guard let source = PowerSource(rawValue: sourceRaw) else {
      throw HelperProtocolError.invalidPowerSource(sourceRaw)
    }
    if let percentage, !(0...100).contains(percentage) {
      throw HelperProtocolError.invalidPercentage(percentage)
    }
    guard sampledAt.timeIntervalSinceReferenceDate.isFinite else {
      throw HelperProtocolError.invalidSampleDate
    }
    guard let batteryFloor = BatteryFloor(floor) else {
      throw HelperProtocolError.invalidBatteryFloor(floor ?? 0)
    }

    protocolVersion = version
    sample = PowerSample(source: source, percentage: percentage, sampledAt: sampledAt)
    self.floor = batteryFloor
    super.init()
  }

  public required convenience init?(coder: NSCoder) {
    let hasPercentage = coder.decodeBool(forKey: CodingKey.hasPercentage)
    let percentage = hasPercentage ? coder.decodeInteger(forKey: CodingKey.percentage) : nil
    let hasFloor = coder.decodeBool(forKey: CodingKey.hasFloor)
    let floor = hasFloor ? coder.decodeInteger(forKey: CodingKey.floor) : nil
    guard let sampledAt = coder.decodeObject(of: NSDate.self, forKey: CodingKey.sampledAt) as Date?
    else {
      return nil
    }

    do {
      try self.init(
        validatingVersion: coder.decodeInteger(forKey: CodingKey.protocolVersion),
        sourceRaw: coder.decodeInteger(forKey: CodingKey.source),
        percentage: percentage,
        sampledAt: sampledAt,
        floor: floor
      )
    } catch {
      return nil
    }
  }

  public func encode(with coder: NSCoder) {
    coder.encode(protocolVersion, forKey: CodingKey.protocolVersion)
    coder.encode(sample.source.rawValue, forKey: CodingKey.source)
    coder.encode(sample.percentage != nil, forKey: CodingKey.hasPercentage)
    if let percentage = sample.percentage {
      coder.encode(percentage, forKey: CodingKey.percentage)
    }
    coder.encode(sample.sampledAt as NSDate, forKey: CodingKey.sampledAt)
    coder.encode(floor.percentage != nil, forKey: CodingKey.hasFloor)
    if let floor = floor.percentage {
      coder.encode(floor, forKey: CodingKey.floor)
    }
  }

  private enum CodingKey {
    static let protocolVersion = "protocolVersion"
    static let source = "source"
    static let hasPercentage = "hasPercentage"
    static let percentage = "percentage"
    static let sampledAt = "sampledAt"
    static let hasFloor = "hasFloor"
    static let floor = "floor"
  }
}

@objc(LidlessHelperStatusMessage)
public final class HelperStatusMessage: NSObject, NSSecureCoding {
  public static let supportsSecureCoding = true

  public let status: HelperStatus

  public init(status: HelperStatus) {
    self.status = status
    super.init()
  }

  public required init?(coder: NSCoder) {
    guard let state = HelperState(rawValue: coder.decodeInteger(forKey: CodingKey.state)) else {
      return nil
    }

    let sessionID = coder.decodeObject(of: NSUUID.self, forKey: CodingKey.sessionID) as UUID?
    let hasLeaseDeadline = coder.decodeBool(forKey: CodingKey.hasLeaseDeadline)
    let leaseDeadline = hasLeaseDeadline ? coder.decodeDouble(forKey: CodingKey.leaseDeadline) : nil
    if let leaseDeadline, !leaseDeadline.isFinite {
      return nil
    }

    let lastDisarmReason: DisarmReason?
    if coder.decodeBool(forKey: CodingKey.hasLastDisarmReason) {
      guard
        let value = DisarmReason(rawValue: coder.decodeInteger(forKey: CodingKey.lastDisarmReason))
      else {
        return nil
      }
      lastDisarmReason = value
    } else {
      lastDisarmReason = nil
    }

    let fault: HelperFault?
    if coder.decodeBool(forKey: CodingKey.hasFault) {
      guard let value = HelperFault(rawValue: coder.decodeInteger(forKey: CodingKey.fault)) else {
        return nil
      }
      fault = value
    } else {
      fault = nil
    }

    status = HelperStatus(
      state: state,
      sessionID: sessionID,
      leaseDeadline: leaseDeadline,
      lastDisarmReason: lastDisarmReason,
      fault: fault
    )
    super.init()
  }

  public func encode(with coder: NSCoder) {
    coder.encode(status.state.rawValue, forKey: CodingKey.state)
    if let sessionID = status.sessionID {
      coder.encode(sessionID as NSUUID, forKey: CodingKey.sessionID)
    }
    coder.encode(status.leaseDeadline != nil, forKey: CodingKey.hasLeaseDeadline)
    if let leaseDeadline = status.leaseDeadline {
      coder.encode(leaseDeadline, forKey: CodingKey.leaseDeadline)
    }
    coder.encode(status.lastDisarmReason != nil, forKey: CodingKey.hasLastDisarmReason)
    if let lastDisarmReason = status.lastDisarmReason {
      coder.encode(lastDisarmReason.rawValue, forKey: CodingKey.lastDisarmReason)
    }
    coder.encode(status.fault != nil, forKey: CodingKey.hasFault)
    if let fault = status.fault {
      coder.encode(fault.rawValue, forKey: CodingKey.fault)
    }
  }

  private enum CodingKey {
    static let state = "state"
    static let sessionID = "sessionID"
    static let hasLeaseDeadline = "hasLeaseDeadline"
    static let leaseDeadline = "leaseDeadline"
    static let hasLastDisarmReason = "hasLastDisarmReason"
    static let lastDisarmReason = "lastDisarmReason"
    static let hasFault = "hasFault"
    static let fault = "fault"
  }
}

public enum HelperReplyCode: Int, Equatable, Sendable {
  case ok
  case unsafePower
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
  case invalidRequest
  case externallyDisabled
  case notReady
}

@objc(LidlessHelperReply)
public final class HelperReply: NSObject, NSSecureCoding {
  public static let supportsSecureCoding = true

  public let code: HelperReplyCode
  public let status: HelperStatusMessage
  public var succeeded: Bool { code == .ok }

  public init(code: HelperReplyCode, status: HelperStatusMessage) {
    self.code = code
    self.status = status
    super.init()
  }

  public required init?(coder: NSCoder) {
    guard let code = HelperReplyCode(rawValue: coder.decodeInteger(forKey: CodingKey.code)),
      let status = coder.decodeObject(of: HelperStatusMessage.self, forKey: CodingKey.status)
    else {
      return nil
    }
    self.code = code
    self.status = status
    super.init()
  }

  public func encode(with coder: NSCoder) {
    coder.encode(code.rawValue, forKey: CodingKey.code)
    coder.encode(status, forKey: CodingKey.status)
  }

  private enum CodingKey {
    static let code = "code"
    static let status = "status"
  }
}

@objc public protocol LidlessHelperXPC {
  func status(reply: @escaping (HelperStatusMessage) -> Void)
  func arm(_ sample: PowerSampleMessage, reply: @escaping (HelperReply) -> Void)
  func renew(sessionID: NSUUID, sample: PowerSampleMessage, reply: @escaping (HelperReply) -> Void)
  func disarm(sessionID: NSUUID, reason: Int, reply: @escaping (HelperReply) -> Void)
  func removeRecognizedLegacyGrant(reply: @escaping (HelperReply) -> Void)
  func restoreNormalSleepAfterConfirmation(reply: @escaping (HelperReply) -> Void)
  func restartAfterVerifiedUpdateSwap(reply: @escaping (HelperReply) -> Void)
}

public enum HelperXPCInterfaces {
  public static func make() -> NSXPCInterface {
    let interface = NSXPCInterface(with: LidlessHelperXPC.self)
    let sampleClasses = allowedClasses(PowerSampleMessage.self)
    let replyClasses = allowedClasses(HelperReply.self, HelperStatusMessage.self)
    let statusClasses = allowedClasses(HelperStatusMessage.self)

    interface.setClasses(
      sampleClasses,
      for: NSSelectorFromString("arm:reply:"),
      argumentIndex: 0,
      ofReply: false
    )
    interface.setClasses(
      sampleClasses,
      for: NSSelectorFromString("renewWithSessionID:sample:reply:"),
      argumentIndex: 1,
      ofReply: false
    )

    for selector in [
      "arm:reply:",
      "renewWithSessionID:sample:reply:",
      "disarmWithSessionID:reason:reply:",
      "removeRecognizedLegacyGrantWithReply:",
      "restoreNormalSleepAfterConfirmationWithReply:",
      "restartAfterVerifiedUpdateSwapWithReply:",
    ] {
      interface.setClasses(
        replyClasses,
        for: NSSelectorFromString(selector),
        argumentIndex: 0,
        ofReply: true
      )
    }
    interface.setClasses(
      statusClasses,
      for: NSSelectorFromString("statusWithReply:"),
      argumentIndex: 0,
      ofReply: true
    )
    return interface
  }

  private static func allowedClasses(_ classes: AnyClass...) -> Set<AnyHashable> {
    // Foundation imports NSSet<Class> as Set<AnyHashable>; metatypes require this bridge.
    NSSet(array: classes) as! Set<AnyHashable>
  }
}
