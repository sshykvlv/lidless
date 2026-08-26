import Foundation

public enum CutoffReason: Equatable, Sendable {
    case atBatteryFloor
    case unknownPower
    case missingPercentage
    case staleSample
    case futureSample
}

public enum SafetyDecision: Equatable, Sendable {
    case allow
    case cutoff(CutoffReason)
}

public enum SafetyPolicy {
    public static let maximumSampleAge: TimeInterval = 15
    public static let maximumFutureSkew: TimeInterval = 5

    public static func evaluate(sample: PowerSample, floor: BatteryFloor, now: Date) -> SafetyDecision {
        guard let floorPercentage = floor.percentage else {
            return .allow
        }

        let sampleAge = now.timeIntervalSince(sample.sampledAt)
        if sampleAge > maximumSampleAge {
            return .cutoff(.staleSample)
        }
        if sampleAge < -maximumFutureSkew {
            return .cutoff(.futureSample)
        }

        switch sample.source {
        case .ac, .charging:
            return .allow
        case .unknown:
            return .cutoff(.unknownPower)
        case .battery:
            guard let percentage = sample.percentage else {
                return .cutoff(.missingPercentage)
            }
            return percentage <= floorPercentage ? .cutoff(.atBatteryFloor) : .allow
        }
    }
}
