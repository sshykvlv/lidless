import Cocoa
import ServiceManagement
import IOKit.ps
import CryptoKit

// Пути фиксированные — sudoers разрешает ровно `pmset -a disablesleep 0|1`
let pmsetPath = "/usr/bin/pmset"
let sudoPath = "/usr/bin/sudo"
let donateURL = "https://buy.stripe.com/5kQ14ogr4dq9fky4Mm0Jq02"   // Stripe Payment Link (pay-what-you-want, NORM)
let repoURL = "https://github.com/sshykvlv/lidless"
// Auto-update принимает ТОЛЬКО бинарь, подписанный этим Developer ID Team ID.
let expectedTeamID = "J2Q78NFXZX"
let expectedAssetName = "Lidless.zip"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()

    private let toggleItem  = NSMenuItem(title: "Keep Awake with Lid Closed", action: #selector(toggleKeepAwake), keyEquivalent: "")
    private let warningItem = NSMenuItem(title: "On — keep an eye on battery & heat", action: nil, keyEquivalent: "")
    private let statusLine  = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let batteryParent = NSMenuItem(title: "Battery cutoff", action: nil, keyEquivalent: "")
    private let loginItem   = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(updatesClicked), keyEquivalent: "")
    private var pendingUpdate: (version: String, zip: URL, sums: URL?)?

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

        let menu = statusMenu
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

        // Меню НЕ назначаем через statusItem.menu — иначе macOS перехватывает клик
        // до нас и Option+click отличить нельзя. Вместо этого сами решаем на action:
        // с зажатым Option — мгновенный toggle без открытия меню, иначе — обычное меню.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

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
            // ВНИМАНИЕ: строка ниже собирает shell-команду интерполяцией и выполняется
            // `with administrator privileges` (root). Безопасно ТОЛЬКО потому, что обе
            // подстановки — константы (pmsetPath фиксирован, value ∈ {"0","1"}).
            // Никогда не делай pmsetPath или value динамическими/вводимыми пользователем —
            // иначе это превращается в root-инъекцию команды.
            let script = "do shell script \"\(pmsetPath) -a disablesleep \(value)\" with administrator privileges"
            _ = run("/usr/bin/osascript", ["-e", script])
        }
        refresh()
    }

    @objc private func toggleKeepAwake() { setKeepAwake(!isKeepAwakeOn()) }

    // Option+click по иконке — мгновенный toggle, без открытия меню.
    // Обычный клик (любая кнопка) — показываем меню как раньше.
    @objc private func statusItemClicked(_ sender: Any) {
        if NSEvent.modifierFlags.contains(.option) {
            toggleKeepAwake()
            return
        }
        statusItem.menu = statusMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

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
            func assetURL(_ match: (String) -> Bool) -> URL? {
                for a in assets {
                    if let name = a["name"] as? String, match(name),
                       let s = a["browser_download_url"] as? String, let u = URL(string: s) { return u }
                }
                return nil
            }
            // Пин на точное имя ассета; фолбэк на первый .zip — подпись всё равно проверяется при установке.
            let zip = assetURL { $0 == expectedAssetName } ?? assetURL { $0.hasSuffix(".zip") }
            let sums = assetURL { $0 == "SHA256SUMS" }
            DispatchQueue.main.async {
                if self.isNewer(latest, than: self.version), let z = zip {
                    self.pendingUpdate = (latest, z, sums)
                    self.updatesItem.attributedTitle = self.updatesAttr("↓ Update available", ver: latest)
                    if announce { self.downloadUpdate((latest, z, sums)) }
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

    private func downloadUpdate(_ up: (version: String, zip: URL, sums: URL?)) {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let zipPath = downloads.appendingPathComponent("Lidless-v\(safeVersion(up.version)).zip")
        let appPath = downloads.appendingPathComponent("Lidless.app")
        updatesItem.attributedTitle = updatesAttr("Downloading…", ver: up.version)
        URLSession.shared.downloadTask(with: up.zip) { [weak self] tmp, _, err in
            guard let self else { return }
            func fail(_ title: String, _ msg: String) {
                DispatchQueue.main.async {
                    self.updatesItem.attributedTitle = self.updatesAttr("Check for Updates…", ver: self.version)
                    self.alert(title, msg)
                    self.open(self.repoURLReleases)
                }
            }
            guard let tmp, err == nil else { fail("Download failed", "Opening the releases page instead."); return }

            // Сохраняем скачанный архив
            try? FileManager.default.removeItem(at: zipPath)
            guard (try? FileManager.default.moveItem(at: tmp, to: zipPath)) != nil else {
                fail("Download failed", "Couldn’t save the update."); return
            }

            // 1) Целостность: SHA-256 против опубликованного SHA256SUMS (если ассет есть).
            if let sums = up.sums {
                let sumsText = self.fetchText(sums, timeout: 15) ?? ""
                guard let expected = self.expectedHash(in: sumsText, for: expectedAssetName),
                      let actual = self.sha256(ofFileAt: zipPath) else {
                    try? FileManager.default.removeItem(at: zipPath)
                    fail("Update verification failed", "Couldn’t verify the download’s checksum. Grab it from the releases page.")
                    return
                }
                guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                    try? FileManager.default.removeItem(at: zipPath)
                    fail("Update verification failed", "Checksum mismatch — the download was not trusted and has been removed.")
                    return
                }
            }

            // Распаковка
            try? FileManager.default.removeItem(at: appPath)
            _ = self.run("/usr/bin/ditto", ["-x", "-k", zipPath.path, downloads.path])
            guard FileManager.default.fileExists(atPath: appPath.path) else {
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([zipPath])
                    self.updatesItem.attributedTitle = self.updatesAttr("Downloaded")
                }
                return
            }

            // 2) Подлинность: валидная подпись Developer ID + ожидаемый Team ID.
            //    Это главный барьер цепочки поставки — подделать без приватного ключа нельзя.
            guard self.codesignValid(appPath), self.teamID(of: appPath) == expectedTeamID else {
                try? FileManager.default.removeItem(at: appPath)
                try? FileManager.default.removeItem(at: zipPath)
                fail("Update rejected",
                     "The downloaded app isn’t signed by Lidless’s Developer ID, so it was removed. Download manually from the releases page.")
                return
            }

            // Проверено → показываем готовую .app, а не архив
            try? FileManager.default.removeItem(at: zipPath)
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([appPath])
                self.updatesItem.attributedTitle = self.updatesAttr("Verified — drag to /Applications")
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
        do { try p.run() } catch { return nil }
        // Читаем ДО waitUntilExit: иначе крупный вывод переполнит буфер пайпа,
        // процесс зависнет на write, а wait — навсегда (классический дедлок).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // Запуск с кодом возврата + stdout + stderr (codesign пишет метаданные в stderr).
    @discardableResult
    private func runStatus(_ path: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        do { try p.run() } catch { return (-1, "", "") }
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(data: od, encoding: .utf8) ?? "",
                String(data: ed, encoding: .utf8) ?? "")
    }

    // SHA-256 файла в hex (нижний регистр).
    private func sha256(ofFileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Достаёт ожидаемый хэш из текста SHA256SUMS (строки вида "<hash>␣␣<filename>").
    private func expectedHash(in sumsText: String, for filename: String) -> String? {
        for line in sumsText.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).filter { !$0.isEmpty }
            if cols.count >= 2, cols.last.map(String.init) == filename { return String(cols[0]) }
        }
        return nil
    }

    // Валидность подписи кода (строгая проверка bundle, включая вложенный код).
    private func codesignValid(_ app: URL) -> Bool {
        runStatus("/usr/bin/codesign", ["--verify", "--strict", app.path]).status == 0
    }

    // Team ID из подписи: `codesign -dvvv` печатает "TeamIdentifier=XX…" в stderr.
    private func teamID(of app: URL) -> String? {
        let r = runStatus("/usr/bin/codesign", ["-dvvv", app.path])
        for line in (r.err + "\n" + r.out).split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            if line.hasPrefix("TeamIdentifier=") {
                return String(line.dropFirst("TeamIdentifier=".count))
            }
        }
        return nil
    }

    // Имя файла из tag_name недоверенное (API/MITM) — оставляем только безопасные
    // символы, чтобы исключить path traversal (`v../../…`) при удалении/записи.
    private func safeVersion(_ v: String) -> String {
        let s = v.filter { ($0.isASCII && $0.isLetter) || $0.isNumber || $0 == "." || $0 == "-" }
        return s.isEmpty ? "update" : s
    }

    // Загрузка маленького текстового ассета (SHA256SUMS) с жёстким таймаутом —
    // не блокируем поток бесконечно, если CDN тупит.
    private func fetchText(_ url: URL, timeout: TimeInterval) -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var result: String?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data { result = String(data: data, encoding: .utf8) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return result
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
