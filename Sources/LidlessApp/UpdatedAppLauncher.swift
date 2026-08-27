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

enum UpdateLaunchHandshake {
  static let readyName = Notification.Name("lv.ykv.lidless.update-ready")
  static let commitName = Notification.Name("lv.ykv.lidless.update-commit")
  static let committedName = Notification.Name("lv.ykv.lidless.update-committed")
  static let tokenKey = "token"
}

@MainActor
final class DistributedTokenWaiter {
  private let token: String
  private var observer: NSObjectProtocol?
  private var continuation: CheckedContinuation<Void, any Error>?
  private var timeoutTask: Task<Void, Never>?
  private var signaled = false

  init(name: Notification.Name, token: String) {
    self.token = token
    observer = DistributedNotificationCenter.default().addObserver(
      forName: name,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      let receivedToken = notification.userInfo?[UpdateLaunchHandshake.tokenKey] as? String
      Task { @MainActor [weak self, receivedToken] in
        guard receivedToken == self?.token else { return }
        self?.finish(.success(()))
      }
    }
  }

  func wait(timeout: Duration) async throws {
    if signaled { return }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        if signaled {
          continuation.resume()
          return
        }
        self.continuation = continuation
        timeoutTask = Task { @MainActor [weak self] in
          do {
            try await Task.sleep(for: timeout)
          } catch {
            return
          }
          self?.finish(.failure(UpdatedAppLauncherError.confirmationTimedOut))
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.finish(.failure(CancellationError()))
      }
    }
  }

  func cancel() {
    finish(.failure(CancellationError()))
  }

  private func finish(_ result: Result<Void, any Error>) {
    if case .success = result {
      signaled = true
    }
    timeoutTask?.cancel()
    timeoutTask = nil
    if let observer {
      DistributedNotificationCenter.default().removeObserver(observer)
      self.observer = nil
    }
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(with: result)
  }
}

@MainActor
final class UpdatedAppLauncher: UpdatedAppLaunching {
  func launchNewInstance(
    app: URL,
    expectedVersion: SemanticVersion,
    oldAppSibling: URL
  ) async throws -> Int32 {
    let confirmationToken = UUID().uuidString
    let readyWaiter = DistributedTokenWaiter(
      name: UpdateLaunchHandshake.readyName,
      token: confirmationToken
    )
    defer { readyWaiter.cancel() }
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

    do {
      try await readyWaiter.wait(timeout: .seconds(10))
      guard matches(launched, app: app, version: expectedVersion) else {
        throw UpdatedAppLauncherError.processMismatch
      }

      let committedWaiter = DistributedTokenWaiter(
        name: UpdateLaunchHandshake.committedName,
        token: confirmationToken
      )
      defer { committedWaiter.cancel() }
      DistributedNotificationCenter.default().postNotificationName(
        UpdateLaunchHandshake.commitName,
        object: nil,
        userInfo: [UpdateLaunchHandshake.tokenKey: confirmationToken],
        deliverImmediately: true
      )
      try await committedWaiter.wait(timeout: .seconds(5))
      guard matches(launched, app: app, version: expectedVersion) else {
        throw UpdatedAppLauncherError.processMismatch
      }
      return launched.processIdentifier
    } catch {
      await terminateBeforeRollback(launched)
      throw error
    }
  }

  private func matches(
    _ application: NSRunningApplication,
    app: URL,
    version: SemanticVersion
  ) -> Bool {
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

  private func terminateBeforeRollback(_ application: NSRunningApplication) async {
    guard !application.isTerminated else { return }
    application.terminate()
    let deadline = ContinuousClock.now + .seconds(2)
    while !application.isTerminated, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
    if !application.isTerminated {
      application.forceTerminate()
    }
  }
}
