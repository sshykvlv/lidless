import Foundation
import XCTest
@testable import LidlessCore

final class SafetyPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBatteryAboveFloorAllowsLease() {
        XCTAssertEqual(decide(.battery, 11, floor: 10), .allow)
    }

    func testBatteryAtOrBelowFloorCutsOff() {
        XCTAssertEqual(decide(.battery, 10, floor: 10), .cutoff(.atBatteryFloor))
        XCTAssertEqual(decide(.battery, 9, floor: 10), .cutoff(.atBatteryFloor))
    }

    func testACAndChargingAllowLease() {
        XCTAssertEqual(decide(.ac, nil, floor: 10), .allow)
        XCTAssertEqual(decide(.charging, 5, floor: 10), .allow)
    }

    func testUnknownOrMissingBatteryFailsClosedWithFloor() {
        XCTAssertEqual(decide(.unknown, nil, floor: 10), .cutoff(.unknownPower))
        XCTAssertEqual(decide(.battery, nil, floor: 10), .cutoff(.missingPercentage))
    }

    func testDisabledFloorAllowsAnyFreshSample() {
        XCTAssertEqual(decide(.unknown, nil, floor: nil), .allow)
        XCTAssertEqual(decide(.battery, 0, floor: nil), .allow)
    }

    func testStaleSampleBoundaryIsInclusive() {
        let justFresh = PowerSample(
            source: .battery,
            percentage: 90,
            sampledAt: now.addingTimeInterval(-15)
        )
        let stale = PowerSample(
            source: .battery,
            percentage: 90,
            sampledAt: now.addingTimeInterval(-15.001)
        )

        XCTAssertEqual(SafetyPolicy.evaluate(sample: justFresh, floor: BatteryFloor(10)!, now: now), .allow)
        XCTAssertEqual(SafetyPolicy.evaluate(sample: stale, floor: BatteryFloor(10)!, now: now), .cutoff(.staleSample))
    }

    func testFutureSampleSkewBoundaryIsInclusive() {
        let acceptable = PowerSample(
            source: .ac,
            percentage: nil,
            sampledAt: now.addingTimeInterval(5)
        )
        let future = PowerSample(
            source: .ac,
            percentage: nil,
            sampledAt: now.addingTimeInterval(5.001)
        )

        XCTAssertEqual(SafetyPolicy.evaluate(sample: acceptable, floor: BatteryFloor(10)!, now: now), .allow)
        XCTAssertEqual(SafetyPolicy.evaluate(sample: future, floor: BatteryFloor(10)!, now: now), .cutoff(.futureSample))
    }

    func testBatteryFloorValidation() {
        XCTAssertEqual(BatteryFloor(nil)?.percentage, nil)
        XCTAssertEqual(BatteryFloor(1)?.percentage, 1)
        XCTAssertEqual(BatteryFloor(100)?.percentage, 100)
        XCTAssertNil(BatteryFloor(0))
        XCTAssertNil(BatteryFloor(101))
    }

    func testMenuOffersOnlyPlainSafeCutoffChoices() {
        XCTAssertEqual(BatteryFloor.menuPercentages, [nil, 10, 20, 30])
        XCTAssertEqual(BatteryFloor.normalizedMenuPercentage(5), 10)
        XCTAssertEqual(BatteryFloor.normalizedMenuPercentage(15), 20)
        XCTAssertEqual(BatteryFloor.normalizedMenuPercentage(99), 10)
    }

    private func decide(_ source: PowerSource, _ percentage: Int?, floor: Int?) -> SafetyDecision {
        let sample = PowerSample(source: source, percentage: percentage, sampledAt: now)
        return SafetyPolicy.evaluate(sample: sample, floor: BatteryFloor(floor)!, now: now)
    }
}
