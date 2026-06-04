import Cocoa
import ServiceManagement
import IOKit.ps

// Пути фиксированные — sudoers разрешает ровно /usr/bin/pmset
let pmsetPath = "/usr/bin/pmset"
let sudoPath = "/usr/bin/sudo"
let donateURL = "https://buy.stripe.com/5kQ14ogr4dq9fky4Mm0Jq02"   // Stripe Payment Link (pay-what-you-want, NORM)
let repoURL = "https://github.com/sshykvlv/lidless"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!

    private let toggleItem  = NSMenuItem(title: "Keep Awake with Lid Closed", action: #selector(toggleKeepAwake), keyEquivalent: "")
    private let warningItem = NSMenuItem(title: "On — keep an eye on battery & heat", action: nil, keyEquivalent: "")
    private let statusLine  = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let batteryParent = NSMenuItem(title: "Battery cutoff", action: nil, keyEquivalent: "")
    private let loginItem   = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(updatesClicked), keyEquivalent: "")
    private var pendingUpdate: (version: String, url: URL)?

    // Единственное подменю — отсечка по батарее (жёсткий минимализм).
    private let floorOptions: [(String, Int)] = [("Off", 0), ("10%", 10), ("20%", 20), ("30%", 30)]
    private var batteryFloor: Int {
        get { UserDefaults.standard.integer(forKey: "batteryFloor") }
        set { UserDefaults.standard.set(newValue, forKey: "batteryFloor") }
    }
    private var batteryTimer: Timer?

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
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

        // Группа настроек: battery floor + launch (без разделителя между ними)
        batteryParent.submenu = buildFloorMenu()
        menu.addItem(batteryParent)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())

        // Мета-группа: донат, GitHub, апдейты
        let donate = NSMenuItem(title: "L✦ve it? Leave a tip", action: #selector(openDonate), keyEquivalent: "")
        donate.target = self
        donate.attributedTitle = donateAttr()
        menu.addItem(donate)
        addLink(to: menu, title: "View on GitHub", action: #selector(openRepo))
        updatesItem.target = self
        updatesItem.attributedTitle = updatesAttr("Check for Updates…", ver: version)
        menu.addItem(updatesItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Lidless", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        batteryTimer = Timer.scheduledTimer(timeInterval: 60, target: self,
                                            selector: #selector(checkBatteryFloor), userInfo: nil, repeats: true)
        refresh()
        checkUpdates(announce: false)  // тихая авто-проверка при запуске
    }

    // MARK: - Меню

    private func buildFloorMenu() -> NSMenu {
        let m = NSMenu()
        for (i, opt) in floorOptions.enumerated() {
            let it = NSMenuItem(title: opt.0, action: #selector(selectFloor(_:)), keyEquivalent: "")
            it.target = self; it.tag = i
            m.addItem(it)
        }
        return m
    }

    private func addLink(to menu: NSMenu, title: String, action: Selector) {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        menu.addItem(it)
    }

    // Заголовок «Check for Updates…» + версия мелким серым справа
    private func updatesAttr(_ main: String, ver: String? = nil) -> NSAttributedString {
        let s = NSMutableAttributedString(string: main, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        if let ver = ver {
            s.append(NSAttributedString(string: "   v\(ver)", attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return s
    }

    // «L✦ve it? Leave a tip» — звезда крупнее и золотая
    private func donateAttr() -> NSAttributedString {
        let f = NSFont.menuFont(ofSize: 0)
        let small = NSFont.menuFont(ofSize: f.pointSize - 1)  // чуть мельче, цвет как у текста
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "L", attributes: [.font: f]))
        s.append(NSAttributedString(string: "✦", attributes: [.font: small]))
        s.append(NSAttributedString(string: "ve it? Leave a tip", attributes: [.font: f]))
        return s
    }

    // MARK: - Состояние

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
        _ = run(sudoPath, ["-n", pmsetPath, "-a", "disablesleep", value])
        if isKeepAwakeOn() != on {
            let script = "do shell script \"\(pmsetPath) -a disablesleep \(value)\" with administrator privileges"
            _ = run("/usr/bin/osascript", ["-e", script])
        }
        refresh()
    }

    @objc private func toggleKeepAwake() { setKeepAwake(!isKeepAwakeOn()) }

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
                  let mx = desc[kIOPSMaxCapacityKey] as? Int, mx > 0
            else { continue }
            let pct = Int((Double(cur) / Double(mx)) * 100.0)
            let onBatt = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            return (onBatt, pct)
        }
        return nil
    }

    @objc private func checkBatteryFloor() {
        guard isKeepAwakeOn(), batteryFloor > 0,
              let b = batteryInfo(), b.onBattery, b.percent <= batteryFloor
        else { return }
        setKeepAwake(false)  // не дать разрядить в ноль
    }

    // MARK: - Прочее

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

    @objc private func openDonate() { open(donateURL) }
    @objc private func openRepo()   { open(repoURL) }
    private func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }

    // MARK: - Авто-проверка апдейтов (A+: сама находит и качает zip в Downloads)

    @objc private func updatesClicked() {
        if let up = pendingUpdate { downloadUpdate(up) }
        else { checkUpdates(announce: true) }
    }

    private func checkUpdates(announce: Bool) {
        guard let api = URL(string: "https://api.github.com/repos/sshykvlv/lidless/releases/latest") else { return }
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                if announce { DispatchQueue.main.async { self.alert("Couldn’t check for updates", "Please try again later.") } }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = json["assets"] as? [[String: Any]] ?? []
            let zip = assets.compactMap { a -> String? in
                ((a["name"] as? String)?.hasSuffix(".zip") == true) ? a["browser_download_url"] as? String : nil
            }.first
            DispatchQueue.main.async {
                if self.isNewer(latest, than: self.version), let z = zip, let u = URL(string: z) {
                    self.pendingUpdate = (latest, u)
                    self.updatesItem.attributedTitle = self.updatesAttr("↓ Update available", ver: latest)
                    if announce { self.downloadUpdate((latest, u)) }
                } else {
                    self.pendingUpdate = nil
                    self.updatesItem.attributedTitle = self.updatesAttr("Check for Updates…", ver: self.version)
                    if announce { self.alert("You’re up to date", "Lidless v\(self.version) is the latest version.") }
                }
            }
        }.resume()
    }

    private func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<Swift.max(x.count, y.count) {
            let xi = i < x.count ? x[i] : 0, yi = i < y.count ? y[i] : 0
            if xi != yi { return xi > yi }
        }
        return false
    }

    private func downloadUpdate(_ up: (version: String, url: URL)) {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let zipPath = downloads.appendingPathComponent("Lidless-v\(up.version).zip")
        let appPath = downloads.appendingPathComponent("Lidless.app")
        updatesItem.attributedTitle = updatesAttr("Downloading…", ver: up.version)
        URLSession.shared.downloadTask(with: up.url) { [weak self] tmp, _, err in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let tmp, err == nil else {
                    self.alert("Download failed", "Opening the releases page instead.")
                    self.open(self.repoURLReleases); return
                }
                try? FileManager.default.removeItem(at: zipPath)
                guard (try? FileManager.default.moveItem(at: tmp, to: zipPath)) != nil else {
                    self.open(self.repoURLReleases); return
                }
                // авто-распаковка → показываем готовую Lidless.app, а не архив
                try? FileManager.default.removeItem(at: appPath)
                _ = self.run("/usr/bin/ditto", ["-x", "-k", zipPath.path, downloads.path])
                if FileManager.default.fileExists(atPath: appPath.path) {
                    try? FileManager.default.removeItem(at: zipPath)
                    NSWorkspace.shared.activateFileViewerSelecting([appPath])
                    self.updatesItem.attributedTitle = self.updatesAttr("Downloaded — drag to /Applications")
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([zipPath])
                    self.updatesItem.attributedTitle = self.updatesAttr("Downloaded")
                }
            }
        }.resume()
    }

    private var repoURLReleases: String { repoURL + "/releases/latest" }

    private func alert(_ title: String, _ msg: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = msg; a.runModal()
    }

    // MARK: - UI

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    private func refresh() {
        let on = isKeepAwakeOn()
        toggleItem.state = on ? .on : .off
        warningItem.isHidden = !on

        if on, let b = batteryInfo() {
            statusLine.title = b.onBattery ? "On battery · \(b.percent)%" : "Charging · \(b.percent)%"
            statusLine.isHidden = false
        } else {
            statusLine.isHidden = true
        }

        let img = makeSparkleImage(on: on)
        img.accessibilityDescription = on ? "Awake with lid closed" : "Normal sleep"
        statusItem.button?.image = img

        if let m = batteryParent.submenu {
            for it in m.items { it.state = (floorOptions[it.tag].1 == batteryFloor) ? .on : .off }
        }
        batteryParent.title = batteryFloor > 0 ? "Off when battery \(batteryFloor)%" : "Battery cutoff: off"

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

    // MARK: - Подпроцесс

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
