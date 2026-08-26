import Foundation

public final class MountedUpdateSession: @unchecked Sendable {
  public let root: URL
  public let diskImage: URL
  public let app: URL
  public let version: SemanticVersion

  private let detachAction: @Sendable () throws -> Void
  private let detachLock = NSLock()
  private var detachResult: Result<Void, any Error>?

  public init(
    root: URL,
    diskImage: URL,
    app: URL,
    version: SemanticVersion,
    detachAction: @escaping @Sendable () throws -> Void
  ) {
    self.root = root
    self.diskImage = diskImage
    self.app = app
    self.version = version
    self.detachAction = detachAction
  }

  public func detach() throws {
    let result = detachLock.withLock { () -> Result<Void, any Error> in
      if let detachResult {
        return detachResult
      }
      let result = Result { try detachAction() }
      detachResult = result
      return result
    }
    try result.get()
  }
}
