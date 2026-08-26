import AppKit
import Darwin
import ServiceManagement

private let arguments = Array(CommandLine.arguments.dropFirst())

if arguments == ["--uninstall-helper"] {
  Task { @MainActor in
    let service = SMAppService.daemon(plistName: "lv.ykv.lidless.helper.plist")
    let client = XPCScheduledHelperClient()
    let outcome = await UninstallCoordinator(client: client, service: service)
      .run(activeCoordinator: nil)
    print(outcome.renderedLine)
    Darwin.exit(outcome.succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
  }
  RunLoop.main.run()
} else if arguments.isEmpty
  || (arguments.count == 4 && arguments[0] == "--cleanup-old-app"
    && arguments[2] == "--confirmation-token")
{
  let cleanupRequest: UpdateLaunchCleanupRequest?
  if arguments.isEmpty {
    cleanupRequest = nil
  } else {
    cleanupRequest = UpdateLaunchCleanupRequest(
      oldAppSibling: URL(fileURLWithPath: arguments[1]),
      token: arguments[3]
    )
  }
  let application = NSApplication.shared
  let delegate = AppDelegate(launchCleanupRequest: cleanupRequest)
  application.delegate = delegate
  application.setActivationPolicy(.accessory)
  application.run()
} else {
  FileHandle.standardError.write(Data("Usage: Lidless [--uninstall-helper]\n".utf8))
  Darwin.exit(EX_USAGE)
}
