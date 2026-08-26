import Foundation

public enum PowerSource: Int, Equatable, Sendable {
    case ac
    case charging
    case battery
    case unknown
}

public struct PowerSample: Equatable, Sendable {
    public let source: PowerSource
    public let percentage: Int?
    public let sampledAt: Date

    public init(source: PowerSource, percentage: Int?, sampledAt: Date) {
        self.source = source
        self.percentage = percentage
        self.sampledAt = sampledAt
    }
}

public struct BatteryFloor: Equatable, Sendable {
    public static let menuPercentages: [Int?] = [nil, 10, 20, 30]

    public let percentage: Int?

    public static func normalizedMenuPercentage(_ stored: Int) -> Int? {
        switch stored {
        case 0:
            return nil
        case 5, 10:
            return 10
        case 15, 20:
            return 20
        case 30:
            return 30
        default:
            return 10
        }
    }

    public init?(_ percentage: Int?) {
        guard let percentage else {
            self.percentage = nil
            return
        }
        guard (1...100).contains(percentage) else {
            return nil
        }
        self.percentage = percentage
    }
}
