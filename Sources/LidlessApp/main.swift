import AppKit

private final class BootstrapAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "✦"
        statusItem = item
    }
}

let application = NSApplication.shared
private let delegate = BootstrapAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
