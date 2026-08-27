import Foundation
import LidlessCore

@main
struct UpdateStagerSmoke {
  static func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 2 else {
      throw SmokeError.usage
    }

    let diskImage = URL(fileURLWithPath: arguments[0])
    let version = try SemanticVersion(arguments[1])
    let session = try UpdateStager().mount(diskImage: diskImage, version: version)
    guard session.app.lastPathComponent == "Lidless.app" else {
      throw SmokeError.unexpectedCandidate
    }
    let privateRoot = session.root
    try session.detach()
    guard !FileManager.default.fileExists(atPath: privateRoot.path) else {
      throw SmokeError.cleanupFailed
    }
    print("UPDATE_STAGER_SMOKE mount=read_only candidate=exact detach=ok cleanup=ok")
  }
}

private enum SmokeError: Error {
  case usage
  case unexpectedCandidate
  case cleanupFailed
}
