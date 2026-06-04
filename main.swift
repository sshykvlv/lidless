import Cocoa
import ServiceManagement
import IOKit.ps

// Пути фиксированные — sudoers разрешает ровно /usr/bin/pmset
let pmsetPath = "/usr/bin/pmset"
let sudoPath = "/usr/bin/sudo"
let donateURL = "https://www.buymeacoffee.com/REPLACE_ME"   // TODO: подставить реальный handle
let repoURL = "https://github.com/sshykvlv/lidless"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!

    private let toggleItem  = NSMenuItem(title: "Keep Awake (Lid Closed)", action: #selector(toggleKeepAwake), keyEquivalent: "")
    private let warningItem = NSMenuItem(title: "On — keep an eye on battery & heat", action: nil, keyEquivalent: "")
    private let statusLine  = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let autoOffParent = NSMenuItem(title: "Auto-off", action: nil, keyEquivalent: "")
    private let batteryParent = NSMenuItem(title: "Battery floor", action: nil, keyEquivalent: "")
    private let loginItem   = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    private let autoOffOptions: [(String, TimeInterval)] = [("Off", 0), ("After 1 hour", 3600), ("After 2 hours", 7200)]
    private let floorOptions:   [(String, Int)]          = [("Off", 0), ("10%", 10), ("15%", 15), ("20%", 20), ("30%", 30)]

    private var autoOffDuration: TimeInterval = 0
    private var autoOffFireDate: Date?
    private var autoOffTimer: Timer?
    private var batteryTimer: Timer?
    private var batteryFloor: Int {
        get { UserDefaults.standard.integer(forKey: "batteryFloor") }
        set { UserDefaults.standard.set(newValue, forKey: "batteryFloor") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.object(forKey: "batteryFloor") == nil { batteryFloor = 20 }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = self
        toggleItem.target = self
        menu.addItem(toggleItem)
        warningItem.isEnabled = false
        menu.addItem(warningItem)
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        autoOffParent.submenu = buildSubmenu(autoOffOptions.map { $0.0 }, action: #selector(selectAutoOff(_:)))
        menu.addItem(autoOffParent)
        batteryParent.submenu = buildSubmenu(floorOptions.map { $0.0 }, action: #selector(selectFloor(_:)))
        menu.addItem(batteryParent)
        menu.addItem(.separator())

        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let donate = NSMenuItem(title: "L✦ve it? Fuel it", action: #selector(openDonate), keyEquivalent: "")
        donate.target = self
        let dt = NSMutableAttributedString(
            string: "L✦ve it? Fuel it\n",
            attributes: [.font: NSFont.menuFont(ofSize: 0)])
        dt.append(NSAttributedString(
            string: "Leave a tip",
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        donate.attributedTitle = dt
        menu.addItem(donate)
        addLink(to: menu, title: "View on GitHub", action: #selector(openRepo))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        batteryTimer = Timer.scheduledTimer(timeInterval: 60, target: self,
                                            selector: #selector(checkBatteryFloor), userInfo: nil, repeats: true)
        refresh()
    }

    // MARK: - Построение меню

    private func buildSubmenu(_ titles: [String], action: Selector) -> NSMenu {
        let m = NSMenu()
        for (i, t) in titles.enumerated() {
            let it = NSMenuItem(title: t, action: action, keyEquivalent: "")
            it.target = self
            it.tag = i
            m.addItem(it)
        }
        return m
    }

    private func addLink(to menu: NSMenu, title: String, action: Selector) {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        menu.addItem(it)
    }

    // MARK: - Чтение/установка состояния

    private func isKeepAwakeOn() -> Bool {
        let out = run(pmsetPath, ["-g"]) ?? ""
        for line in out.split(separator: "\n") {
            let l = line.lowercased()
            if l.contains("sleepdisabled") {
                let parts = l.split(whereSeparator: { $0 == " " || $0 == "\t" })
                return parts.last.map(String.init) == "1"
            }
        }
        return false
    }

    private func setKeepAwake(_ on: Bool) {
        let value = on ? "1" : "0"
        // 1) беспарольно (если есть sudoers drop-in)
        _ = run(sudoPath, ["-n", pmsetPath, "-a", "disablesleep", value])
        // 2) иначе — системное окно с паролем
        if isKeepAwakeOn() != on {
            let script = "do shell script \"\(pmsetPath) -a disablesleep \(value)\" with administrator privileges"
            _ = run("/usr/bin/osascript", ["-e", script])
        }
        if isKeepAwakeOn() && autoOffDuration > 0 { armAutoOff() } else { cancelAutoOff() }
        refresh()
    }

    @objc private func toggleKeepAwake() { setKeepAwake(!isKeepAwakeOn()) }

    // MARK: - Auto-off по таймеру

    private func armAutoOff() {
        cancelAutoOff()
        guard autoOffDuration > 0 else { return }
        autoOffFireDate = Date().addingTimeInterval(autoOffDuration)
        autoOffTimer = Timer.scheduledTimer(withTimeInterval: autoOffDuration, repeats: false) { [weak self] _ in
            self?.setKeepAwake(false)
        }
    }
    private func cancelAutoOff() {
        autoOffTimer?.invalidate(); autoOffTimer = nil; autoOffFireDate = nil
    }

    @objc private func selectAutoOff(_ sender: NSMenuItem) {
        autoOffDuration = autoOffOptions[sender.tag].1
        if isKeepAwakeOn() && autoOffDuration > 0 { armAutoOff() } else { cancelAutoOff() }
        refresh()
    }

    // MARK: - Battery floor

    @objc private func selectFloor(_ sender: NSMenuItem) {
        batteryFloor = floorOptions[sender.tag].1
        refresh()
        checkBatteryFloor()
    }

    private func batteryInfo() -> (onBattery: Bool, percent: Int)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let pct = Int((Double(cur) / Double(max)) * 100.0)
            let onBatt = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            return (onBatt, pct)
        }
        return nil
    }

    @objc private func checkBatteryFloor() {
        guard isKeepAwakeOn(), batteryFloor > 0,
              let b = batteryInfo(), b.onBattery, b.percent <= batteryFloor
        else { return }
        setKeepAwake(false)  // страховка: не дать разрядить в ноль
    }

    // MARK: - Прочие действия

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let a = NSAlert(); a.messageText = "Couldn’t change Launch at Login"
            a.informativeText = error.localizedDescription; a.runModal()
        }
        refresh()
    }

    @objc private func openDonate() { if let u = URL(string: donateURL) { NSWorkspace.shared.open(u) } }
    @objc private func openRepo()   { if let u = URL(string: repoURL)   { NSWorkspace.shared.open(u) } }

    // MARK: - Обновление UI

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    private func refresh() {
        let on = isKeepAwakeOn()
        toggleItem.state = on ? .on : .off
        warningItem.isHidden = !on

        var parts: [String] = []
        if let b = batteryInfo() {
            parts.append(b.onBattery ? "Battery \(b.percent)%" : "Charging \(b.percent)%")
        }
        if on, let fire = autoOffFireDate {
            let rem = Swift.max(0, Int(fire.timeIntervalSinceNow))
            parts.append("auto-off in \(rem / 3600)h \((rem % 3600) / 60)m")
        }
        statusLine.title = parts.joined(separator: " · ")
        statusLine.isHidden = parts.isEmpty

        let img = makeSparkleImage(on: on)
        img.accessibilityDescription = on ? "Awake with lid closed" : "Normal sleep"
        statusItem.button?.image = img

        if let m = autoOffParent.submenu {
            for it in m.items { it.state = (autoOffOptions[it.tag].1 == autoOffDuration) ? .on : .off }
        }
        autoOffParent.title = autoOffDuration > 0 ? "Auto-off: \(Int(autoOffDuration) / 3600)h" : "Auto-off"
        if let m = batteryParent.submenu {
            for it in m.items { it.state = (floorOptions[it.tag].1 == batteryFloor) ? .on : .off }
        }
        batteryParent.title = batteryFloor > 0 ? "Battery floor: \(batteryFloor)%" : "Battery floor"

        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    // MARK: - Иконка меню-бара (фирменная 4-лучевая звезда)

    private func makeSparkleImage(on: Bool) -> NSImage {
        let s: CGFloat = 18
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let scale = (s - 2) / 116.0
            func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: (x - 42) * scale + 1, y: (158 - y) * scale + 1)
            }
            let p = CGMutablePath()
            p.move(to: P(100, 42))
            p.addQuadCurve(to: P(158, 100), control: P(116.81, 83.19))
            p.addQuadCurve(to: P(100, 158), control: P(116.81, 116.81))
            p.addQuadCurve(to: P(42, 100), control: P(83.19, 116.81))
            p.addQuadCurve(to: P(100, 42), control: P(83.19, 83.19))
            p.closeSubpath()
            ctx.addPath(p)
            (on ? NSColor.systemYellow : NSColor.black).setFill()
            ctx.fillPath()
        }
        img.unlockFocus()
        img.isTemplate = !on
        return img
    }

    // MARK: - Запуск подпроцесса

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
