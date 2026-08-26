import AppKit
import Foundation
import LidlessCore

enum UpdatedAppLauncherError: Error, Equatable {
  case launchFailed
  case processMismatch
  case confirmationTimedOut
}

struct UpdateLaunchCleanupRequest: Sendable {
  let oldAppSibling: URL
  let token: String
}

enum UpdateLaunchConfirmation {
  static let name = Notification.Name("lv.ykv.lidless.update-confirmed")
  static let tokenKey = "token"
}

@MainActor
final class UpdatedAppLauncher: UpdatedAppLaunching {
  func launchNewInstance(
    app: URL,
    expectedVersion: SemanticVersion,
    oldAppSibling: URL
  ) async throws -> Int32 {
    let confirmationToken = UUID().uuidString
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.arguments = [
      "--cleanup-old-app", oldAppSibling.path,
      "--confirmation-token", confirmationToken,
    ]

    let launched = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<NSRunningApplication, any Error>) in
      NSWorkspace.shared.openApplication(at: app, configuration: configuration) {
        application, error in
        if let application {
          continuation.resume(returning: application)
        } else {
          continuation.resume(throwing: error ?? UpdatedAppLauncherError.launchFailed)
        }
      }
    }

    let deadline = ContinuousClock.now + .seconds(10)
    repeat {
      if try matches(launched, app: app, version: expectedVersion) {
        try await Task.sleep(for: .milliseconds(250))
        DistributedNotificationCenter.default().postNotificationName(
          UpdateLaunchConfirmation.name,
          object: nil,
          userInfo: [UpdateLaunchConfirmation.tokenKey: confirmationToken],
          deliverImmediately: true
        )
        return launched.processIdentifier
      }
      try await Task.sleep(for: .milliseconds(200))
    } while ContinuousClock.now < deadline
    throw UpdatedAppLauncherError.confirmationTimedOut
  }

  private func matches(
    _ application: NSRunningApplication,
    app: URL,
    version: SemanticVersion
  ) throws -> Bool {
    guard application.processIdentifier > 0,
      application.bundleIdentifier == StagedAppIdentityPolicy.expectedBundleIdentifier,
      application.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path
        == app.standardizedFileURL.resolvingSymlinksInPath().path,
      let bundle = Bundle(url: app),
      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        == version.description
    else {
      return false
    }
    return !application.isTerminated
  }
}
