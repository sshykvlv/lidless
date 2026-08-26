import XCTest
@testable import LidlessCore

final class BuildMarkerTests: XCTestCase {
    func testSupportedVersionMatchesReleaseTarget() {
        XCTAssertEqual(BuildMarker.supportedVersion, "1.1.0")
    }
}
