import XCTest

@testable import LidlessCore

final class MenuStateResolverTests: XCTestCase {
  func testInactiveServiceWithUnverifiableSleepStateIsNotReportedOff() {
    let helper = ObservedHelperStatus(
      status: HelperStatus(
        state: .inactive,
        sessionID: nil,
        leaseDeadline: nil,
        lastDisarmReason: nil,
        fault: nil
      ),
      observedSleepDisabled: nil,
      buildVersion: "1.1.0"
    )

    XCTAssertEqual(
      MenuStateResolver.resolve(service: .enabled, helper: helper, sample: nil),
      .unverified
    )
  }
}
