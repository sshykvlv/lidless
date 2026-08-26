import Foundation
import XCTest

@testable import LidlessCore

@MainActor
final class UpdateLaunchHandshakeTests: XCTestCase {
  func testReadyCommitAndCommittedSignalsAreDistinct() {
    XCTAssertNotEqual(UpdateLaunchHandshake.readyName, UpdateLaunchHandshake.commitName)
    XCTAssertNotEqual(UpdateLaunchHandshake.readyName, UpdateLaunchHandshake.committedName)
    XCTAssertNotEqual(UpdateLaunchHandshake.commitName, UpdateLaunchHandshake.committedName)
  }

  func testTokenWaiterIgnoresWrongTokenUntilMatchingSignal() async throws {
    let token = UUID().uuidString
    let waiter = DistributedTokenWaiter(
      name: UpdateLaunchHandshake.readyName,
      token: token
    )
    let started = ContinuousClock.now
    Task { @MainActor in
      DistributedNotificationCenter.default().postNotificationName(
        UpdateLaunchHandshake.readyName,
        object: nil,
        userInfo: [UpdateLaunchHandshake.tokenKey: "wrong-token"],
        deliverImmediately: true
      )
      try? await Task.sleep(for: .milliseconds(100))
      DistributedNotificationCenter.default().postNotificationName(
        UpdateLaunchHandshake.readyName,
        object: nil,
        userInfo: [UpdateLaunchHandshake.tokenKey: token],
        deliverImmediately: true
      )
    }

    try await waiter.wait(timeout: .seconds(1))

    XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(80))
  }

  func testTokenWaiterTimesOutWithoutMatchingSignal() async {
    let waiter = DistributedTokenWaiter(
      name: UpdateLaunchHandshake.committedName,
      token: UUID().uuidString
    )

    do {
      try await waiter.wait(timeout: .milliseconds(100))
      XCTFail("Expected handshake timeout")
    } catch {
      XCTAssertEqual(error as? UpdatedAppLauncherError, .confirmationTimedOut)
    }
  }
}
