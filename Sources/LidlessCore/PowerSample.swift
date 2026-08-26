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
    public let percentage: Int?

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
