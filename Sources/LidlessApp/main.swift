import AppKit
import Darwin
import ServiceManagement

private let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.isEmpty {
  do {
    let replacer = AtomicAppReplacer(
      validator: StaticCodeValidator(),
      hasher: SHA256FileHasher()
    )
    if try replacer.recoverPendingUpdate(installedApp: Bundle.main.bundleURL) == .rolledBack {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      process.arguments = ["-n", Bundle.main.bundleURL.path]
      try process.run()
      process.waitUntilExit()
      Darwin.exit(process.terminationStatus == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }
  } catch {
    let alert = NSAlert()
    alert.messageText = "Lidless update needs recovery"
    alert.informativeText =
      "Lidless could not safely finish or restore an interrupted update. Reinstall Lidless before using closed-lid mode."
    alert.addButton(withTitle: "Quit")
    alert.runModal()
    Darwin.exit(EXIT_FAILURE)
  }
}

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
