import Foundation
import XCTest

@testable import LidlessCore

final class ProtocolTests: XCTestCase {
  private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

  func testPowerSampleMessageSecureCodingRoundTrip() throws {
    let original = PowerSampleMessage(
      source: .battery,
      percentage: 42,
      sampledAt: fixedDate,
      floor: 10
    )

    let data = try NSKeyedArchiver.archivedData(
      withRootObject: original, requiringSecureCoding: true)
    let decoded = try XCTUnwrap(
      NSKeyedUnarchiver.unarchivedObject(ofClass: PowerSampleMessage.self, from: data)
    )

    XCTAssertEqual(decoded.sample, original.sample)
    XCTAssertEqual(decoded.floor, BatteryFloor(10)!)
    XCTAssertEqual(decoded.protocolVersion, 1)
  }

  func testDisabledFloorAndNilPercentageRoundTrip() throws {
    let original = PowerSampleMessage(
      source: .unknown,
      percentage: nil,
      sampledAt: fixedDate,
      floor: nil
    )
    let data = try NSKeyedArchiver.archivedData(
      withRootObject: original, requiringSecureCoding: true)
    let decoded = try XCTUnwrap(
      NSKeyedUnarchiver.unarchivedObject(ofClass: PowerSampleMessage.self, from: data)
    )

    XCTAssertEqual(decoded.sample.percentage, nil)
    XCTAssertEqual(decoded.floor.percentage, nil)
  }

  func testStatusAndReplySecureCodingRoundTrip() throws {
    let status = HelperStatus(
      state: .active,
      sessionID: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"),
      leaseDeadline: 123.5,
      lastDisarmReason: .batteryFloor,
      fault: nil
    )
    let original = HelperReply(
      code: .ok,
      status: HelperStatusMessage(status: status, observedSleepDisabled: true)
    )

    let data = try NSKeyedArchiver.archivedData(
      withRootObject: original, requiringSecureCoding: true)
    let decoded = try XCTUnwrap(
      NSKeyedUnarchiver.unarchivedObject(ofClass: HelperReply.self, from: data)
    )

    XCTAssertEqual(decoded.code, .ok)
    XCTAssertTrue(decoded.succeeded)
    XCTAssertEqual(decoded.status.status, status)
    XCTAssertEqual(decoded.status.observedSleepDisabled, true)
  }

  func testRequirementsPinIdentifiersAndTeam() {
    XCTAssertEqual(
      CodeSigningRequirements.app,
      "identifier \"lv.ykv.lidless\" and anchor apple generic and certificate leaf[subject.OU] = \"J2Q78NFXZX\""
    )
    XCTAssertEqual(
      CodeSigningRequirements.helper,
      "identifier \"lv.ykv.lidless.helper\" and anchor apple generic and certificate leaf[subject.OU] = \"J2Q78NFXZX\""
    )
  }

  func testRejectsInvalidProtocolVersionAndOutOfRangeFields() {
    XCTAssertThrowsError(
      try PowerSampleMessage(
        validatingVersion: 2,
        sourceRaw: PowerSource.battery.rawValue,
        percentage: 42,
        sampledAt: fixedDate,
        floor: 10
      )
    )
    XCTAssertThrowsError(
      try PowerSampleMessage(
        validatingVersion: 1,
        sourceRaw: 99,
        percentage: 42,
        sampledAt: fixedDate,
        floor: 10
      )
    )
    XCTAssertThrowsError(
      try PowerSampleMessage(
        validatingVersion: 1,
        sourceRaw: PowerSource.battery.rawValue,
        percentage: 101,
        sampledAt: fixedDate,
        floor: 10
      )
    )
    XCTAssertThrowsError(
      try PowerSampleMessage(
        validatingVersion: 1,
        sourceRaw: PowerSource.battery.rawValue,
        percentage: 42,
        sampledAt: fixedDate,
        floor: 0
      )
    )
  }

  func testProtocolExposesOnlyFixedOperations() {
    let requiredSelectors: Set<String> = [
      "statusWithReply:",
      "arm:reply:",
      "renewWithSessionID:sample:reply:",
      "disarmWithSessionID:reason:reply:",
      "removeRecognizedLegacyGrantWithReply:",
      "restoreNormalSleepAfterConfirmationWithReply:",
      "restartAfterVerifiedUpdateSwapWithReply:",
    ]
    let protocolObject = LidlessHelperXPC.self as Protocol
    var methodCount: UInt32 = 0
    let methods = protocol_copyMethodDescriptionList(protocolObject, true, true, &methodCount)
    defer { free(methods) }
    let exportedSelectors = Set(
      (0..<Int(methodCount)).compactMap { index in
        methods?[index].name.map(NSStringFromSelector)
      }
    )

    XCTAssertEqual(exportedSelectors, requiredSelectors)

    for selectorName in requiredSelectors {
      XCTAssertNotNil(
        protocol_getMethodDescription(
          protocolObject,
          NSSelectorFromString(selectorName),
          true,
          true
        ).name,
        "Missing required XPC selector \(selectorName)"
      )
    }
  }
}
