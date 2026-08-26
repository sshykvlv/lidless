import Foundation
import IOKit.ps
import LidlessCore

@MainActor
final class IOKitBatteryMonitor: PowerSampling, BatteryMonitoring {
  private var notificationSource: CFRunLoopSource?
  private var callbackBox: Unmanaged<BatteryNotificationBox>?

  func sample() throws -> PowerSample {
    let sampledAt = Date()
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
      return PowerSample(source: .unknown, percentage: nil, sampledAt: sampledAt)
    }

    let providingType =
      IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
    let internalBattery = internalBatteryDescription(snapshot: snapshot)
    let percentage = internalBattery.flatMap(Self.percentage(from:))

    let source: PowerSource
    switch providingType {
    case kIOPSACPowerValue:
      let isCharging = internalBattery?[kIOPSIsChargingKey] as? Bool ?? false
      source = isCharging ? .charging : .ac
    case kIOPSBatteryPowerValue:
      source = internalBattery == nil ? .unknown : .battery
    default:
      source = .unknown
    }

    return PowerSample(source: source, percentage: percentage, sampledAt: sampledAt)
  }

  func start(_ handler: @escaping @MainActor @Sendable () -> Void) {
    stop()

    let box = Unmanaged.passRetained(BatteryNotificationBox(handler: handler))
    guard
      let source = IOPSNotificationCreateRunLoopSource(
        { context in
          guard let context else {
            return
          }
          Unmanaged<BatteryNotificationBox>.fromOpaque(context).takeUnretainedValue().notify()
        },
        box.toOpaque()
      )?.takeRetainedValue()
    else {
      box.release()
      return
    }

    notificationSource = source
    callbackBox = box
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
  }

  func stop() {
    if let notificationSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), notificationSource, .commonModes)
      CFRunLoopSourceInvalidate(notificationSource)
      self.notificationSource = nil
    }
    callbackBox?.release()
    callbackBox = nil
  }

  isolated deinit {
    if let notificationSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), notificationSource, .commonModes)
      CFRunLoopSourceInvalidate(notificationSource)
    }
    callbackBox?.release()
  }

  private func internalBatteryDescription(snapshot: CFTypeRef) -> [String: Any]? {
    guard
      let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
    else {
      return nil
    }

    for powerSource in sources {
      guard
        let description =
          IOPSGetPowerSourceDescription(snapshot, powerSource)?.takeUnretainedValue()
          as? [String: Any],
        description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
      else {
        continue
      }
      return description
    }
    return nil
  }

  private static func percentage(from description: [String: Any]) -> Int? {
    guard
      let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
      let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
      maximum.doubleValue > 0
    else {
      return nil
    }
    let raw = (current.doubleValue / maximum.doubleValue) * 100
    guard raw.isFinite else {
      return nil
    }
    return min(100, max(0, Int(raw.rounded())))
  }
}

private final class BatteryNotificationBox: @unchecked Sendable {
  private let handler: @MainActor @Sendable () -> Void

  init(handler: @escaping @MainActor @Sendable () -> Void) {
    self.handler = handler
  }

  func notify() {
    Task { @MainActor [handler] in
      handler()
    }
  }
}
