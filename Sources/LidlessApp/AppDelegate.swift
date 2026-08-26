import AppKit
import LidlessCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private static let helperPlistName = "lv.ykv.lidless.helper.plist"
  private static let floorDefaultsKey = "BatteryFloor"
  private static let legacyCleanupDefaultsKey = "LegacyGrantCleanupAttemptedV1"

  private let service = SMAppService.daemon(plistName: helperPlistName)
  private let battery = IOKitBatteryMonitor()
  private let activity = ProcessActivityManager()
  private let scheduler = CommonModeRenewalScheduler()
  private let recorder = DiagnosticRecorder()
  private lazy var notifier = AppSafetyNotifier(recorder: recorder)

  private var helperClient: XPCScheduledHelperClient!
  private var coordinator: SafetyCoordinator!
  private var statusItem: NSStatusItem!
  private let menu = NSMenu()
  private let statusMenuItem = NSMenuItem(
    title: "Checking safety state…", action: nil, keyEquivalent: "")
  private let toggleMenuItem = NSMenuItem(title: "Keep Mac Awake", action: nil, keyEquivalent: "")
  private let setupMenuItem = NSMenuItem(title: "Set Up Helper…", action: nil, keyEquivalent: "")
  private let restoreMenuItem = NSMenuItem(
    title: "Restore Normal Lid Sleep…",
    action: nil,
    keyEquivalent: ""
  )
  private let floorMenu = NSMenu()

  private var statusTimer: Timer?
  private var currentHelperStatus: ObservedHelperStatus?
  private var currentSample: PowerSample?
  private var currentState = MenuSafetyState.helperNotRegistered
  private var refreshInFlight = false
  private var terminationApproved = false
  private var terminationPending = false
  private var isUninstalling = false
  private var didArmInThisRun = false
  private var lastNotifiedFaultCode: String?
  private var helperConnectionInvalidated = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    configureHelperStack()
    buildMenu()
    notifier.onEvent = { [weak self] in
      Task { @MainActor [weak self] in
        await self?.refreshState()
      }
    }
    notifier.requestAuthorization()
    startStatusRefresh()
    Task { @MainActor [weak self] in
      await self?.refreshState()
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminationApproved {
      return .terminateNow
    }
    if terminationPending {
      return .terminateLater
    }

    terminationPending = true
    Task { @MainActor [weak self] in
      guard let self else {
        NSApp.reply(toApplicationShouldTerminate: true)
        return
      }
      await coordinator.disarm(reason: .appQuit)
      stopStatusRefresh()
      terminationApproved = true
      terminationPending = false
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func menuWillOpen(_ menu: NSMenu) {
    Task { @MainActor [weak self] in
      await self?.refreshState()
    }
  }

  @objc private func toggleKeepAwake() {
    Task { @MainActor [weak self] in
      guard let self else { return }

      if coordinator.isArmed {
        await coordinator.disarm(reason: .user)
        await cleanupLegacyGrantAfterVerifiedRoundTrip()
        await refreshState()
        return
      }

      switch serviceAvailability() {
      case .enabled:
        do {
          try await coordinator.arm(floor: configuredFloor())
          didArmInThisRun = true
          AppLog.state.notice("Coordinator armed floor=\(self.configuredFloor().percentage ?? -1)")
        } catch {
          recorder.record("state.arm_failed")
          showAlert(
            title: "Lidless could not start",
            message:
              "Normal lid sleep was left unchanged. Check the helper status and battery floor."
          )
        }
      case .notRegistered:
        confirmAndRegisterHelper()
      case .approvalRequired, .notFound:
        break
      }
      await refreshState()
    }
  }

  @objc private func setBatteryFloor(_ sender: NSMenuItem) {
    let value: Int? = sender.tag == 0 ? nil : sender.tag
    if let value {
      UserDefaults.standard.set(value, forKey: Self.floorDefaultsKey)
    } else {
      UserDefaults.standard.set(0, forKey: Self.floorDefaultsKey)
    }
    updateFloorMenuChecks()
    guard let floor = BatteryFloor(value) else {
      return
    }
    Task { @MainActor [weak self] in
      await self?.coordinator.setFloor(floor)
      await self?.refreshState()
    }
  }

  @objc private func setUpHelper() {
    switch serviceAvailability() {
    case .notRegistered:
      confirmAndRegisterHelper()
    case .approvalRequired:
      guard
        let url = URL(
          string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        )
      else {
        return
      }
      NSWorkspace.shared.open(url)
    case .notFound:
      showAlert(
        title: "Helper is missing",
        message: "Install the complete signed Lidless.app bundle in /Applications and try again."
      )
    case .enabled:
      break
    }
    Task { @MainActor [weak self] in
      await self?.refreshState()
    }
  }

  @objc private func restoreNormalLidSleep() {
    let alert = NSAlert()
    alert.messageText = "Restore normal lid sleep?"
    alert.informativeText =
      "Another tool may own the current keep-awake setting. Lidless will explicitly set it back to normal only if you confirm."
    alert.addButton(withTitle: "Restore")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }

    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        _ = try await helperClient.restoreNormalSleepAfterConfirmation()
        AppLog.state.notice("External keep-awake restored after confirmation")
      } catch {
        recorder.record("helper.restore_failed")
        notifier.restorationFault()
      }
      await refreshState()
    }
  }

  @objc private func copyDiagnostics() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      await refreshState()
      let version =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "unknown"
      let snapshot = DiagnosticSnapshot(
        appVersion: version,
        helperVersion: version,
        service: serviceAvailability(),
        helper: currentHelperStatus,
        sample: currentSample,
        floor: configuredFloor().percentage,
        errorCodes: recorder.latestErrorCodes
      )
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(snapshot.render(), forType: .string)
      statusMenuItem.title = "Diagnostics copied"
    }
  }

  @objc private func uninstallHelper() {
    let alert = NSAlert()
    alert.messageText = "Uninstall the Lidless helper?"
    alert.informativeText =
      "Lidless will restore normal lid sleep, remove only a recognized historical grant, and unregister its fixed helper."
    alert.addButton(withTitle: "Uninstall")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }

    isUninstalling = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      let outcome = await UninstallCoordinator(client: helperClient, service: service)
        .run(activeCoordinator: coordinator)
      showAlert(
        title: outcome.succeeded ? "Helper uninstalled" : "Uninstall needs attention",
        message: outcome.succeeded
          ? "Normal lid sleep was verified. You can now move Lidless.app to the Trash."
          : "Some cleanup could not be verified. Copy diagnostics before removing the app."
      )
      if outcome.succeeded {
        NSApp.terminate(nil)
      } else {
        isUninstalling = false
        await refreshState()
      }
    }
  }

  @objc private func quitLidless() {
    NSApp.terminate(nil)
  }

  private func configureHelperStack() {
    let client = XPCScheduledHelperClient()
    let coordinator = SafetyCoordinator(
      powerSampler: battery,
      batteryMonitor: battery,
      helper: client,
      activity: activity,
      renewalScheduler: scheduler,
      notifier: notifier
    )
    self.helperClient = client
    self.coordinator = coordinator
    helperConnectionInvalidated = false

    client.onInvalidation = { [weak self, weak client] in
      guard let self, let client, helperClient === client else {
        return
      }
      coordinator.helperConnectionLost()
      helperConnectionInvalidated = true
      currentHelperStatus = nil
      recorder.record("helper.connection_lost")
      renderState()
      guard !isUninstalling, service.status == .enabled else {
        return
      }
      Task { @MainActor [weak self, weak client] in
        try? await Task.sleep(for: .seconds(1))
        guard let self, let client, helperClient === client, !isUninstalling else {
          return
        }
        configureHelperStack()
        await refreshState()
      }
    }
  }

  private func buildMenu() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.button?.title = "✦"
    statusItem.menu = menu
    menu.delegate = self

    statusMenuItem.isEnabled = false
    menu.addItem(statusMenuItem)
    menu.addItem(.separator())

    toggleMenuItem.target = self
    toggleMenuItem.action = #selector(toggleKeepAwake)
    menu.addItem(toggleMenuItem)

    let floorItem = NSMenuItem(title: "Battery floor", action: nil, keyEquivalent: "")
    for (title, value) in [("Disabled", 0), ("5%", 5), ("10%", 10), ("15%", 15), ("20%", 20)] {
      let item = NSMenuItem(
        title: title,
        action: #selector(setBatteryFloor(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.tag = value
      floorMenu.addItem(item)
    }
    floorItem.submenu = floorMenu
    menu.addItem(floorItem)

    setupMenuItem.target = self
    setupMenuItem.action = #selector(setUpHelper)
    menu.addItem(setupMenuItem)

    restoreMenuItem.target = self
    restoreMenuItem.action = #selector(restoreNormalLidSleep)
    menu.addItem(restoreMenuItem)
    menu.addItem(.separator())

    let diagnostics = NSMenuItem(
      title: "Copy diagnostics",
      action: #selector(copyDiagnostics),
      keyEquivalent: ""
    )
    diagnostics.target = self
    menu.addItem(diagnostics)

    let uninstall = NSMenuItem(
      title: "Uninstall helper…",
      action: #selector(uninstallHelper),
      keyEquivalent: ""
    )
    uninstall.target = self
    menu.addItem(uninstall)
    menu.addItem(.separator())

    let quit = NSMenuItem(
      title: "Quit Lidless",
      action: #selector(quitLidless),
      keyEquivalent: "q"
    )
    quit.target = self
    menu.addItem(quit)
    updateFloorMenuChecks()
  }

  private func startStatusRefresh() {
    let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        await self?.refreshState()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    statusTimer = timer
  }

  private func stopStatusRefresh() {
    statusTimer?.invalidate()
    statusTimer = nil
  }

  private func refreshState() async {
    guard !refreshInFlight else {
      return
    }
    refreshInFlight = true
    defer { refreshInFlight = false }

    currentSample = try? battery.sample()
    if service.status == .enabled {
      if helperConnectionInvalidated {
        configureHelperStack()
      }
      guard let client = helperClient else {
        currentHelperStatus = nil
        renderState()
        return
      }
      do {
        let status = try await client.status()
        guard client === helperClient else { return }
        currentHelperStatus = status
        if status.status.state == .faulted {
          let faultCode = status.status.fault.map(String.init(describing:)) ?? "unknown"
          if faultCode != lastNotifiedFaultCode {
            lastNotifiedFaultCode = faultCode
            notifier.restorationFault()
          }
        } else {
          lastNotifiedFaultCode = nil
        }
      } catch {
        guard client === helperClient else { return }
        currentHelperStatus = nil
        recorder.record("helper.status_unavailable")
      }
    } else {
      currentHelperStatus = nil
    }
    renderState()
  }

  private func renderState() {
    currentState = MenuStateResolver.resolve(
      service: serviceAvailability(),
      helper: currentHelperStatus,
      sample: currentSample
    )

    let active: Bool
    switch currentState {
    case .armed(let percent, let onBattery):
      active = true
      if onBattery {
        statusMenuItem.title = "On — battery \(percent.map { "\($0)%" } ?? "unknown")"
      } else {
        statusMenuItem.title = "On — external power"
      }
    case .off:
      active = false
      statusMenuItem.title = "Off — normal lid sleep"
    case .externalKeepAwake:
      active = false
      statusMenuItem.title = "Another tool keeps lid sleep disabled"
    case .helperNotRegistered:
      active = false
      statusMenuItem.title = "Helper is not registered"
    case .helperApprovalRequired:
      active = false
      statusMenuItem.title = "Helper approval is required"
    case .restoring:
      active = false
      statusMenuItem.title = "Restoring normal lid sleep…"
    case .fault(let code):
      active = false
      statusMenuItem.title = "Safety fault — \(code.rawValue)"
    }

    toggleMenuItem.state = active ? .on : .off
    toggleMenuItem.isEnabled = toggleIsEnabled(for: currentState)
    setupMenuItem.isHidden = service.status == .enabled
    setupMenuItem.title =
      service.status == .requiresApproval
      ? "Approve Helper in System Settings…" : "Set Up Helper…"
    restoreMenuItem.isHidden = currentState != .externalKeepAwake

    let color: NSColor = active ? .systemYellow : .secondaryLabelColor
    statusItem.button?.attributedTitle = NSAttributedString(
      string: "✦",
      attributes: [.foregroundColor: color]
    )
    updateFloorMenuChecks()
  }

  private func toggleIsEnabled(for state: MenuSafetyState) -> Bool {
    switch state {
    case .off, .armed, .helperNotRegistered:
      return service.status != .notFound
    case .externalKeepAwake, .helperApprovalRequired, .restoring, .fault:
      return false
    }
  }

  private func configuredFloor() -> BatteryFloor {
    if UserDefaults.standard.object(forKey: Self.floorDefaultsKey) == nil {
      UserDefaults.standard.set(10, forKey: Self.floorDefaultsKey)
    }
    let stored = UserDefaults.standard.integer(forKey: Self.floorDefaultsKey)
    let value: Int? = stored == 0 ? nil : stored
    guard let floor = BatteryFloor(value) else {
      guard let fallback = BatteryFloor(10) else {
        preconditionFailure("The fixed 10 percent floor must be valid")
      }
      return fallback
    }
    return floor
  }

  private func updateFloorMenuChecks() {
    let configured = configuredFloor().percentage ?? 0
    for item in floorMenu.items {
      item.state = item.tag == configured ? .on : .off
    }
  }

  private func serviceAvailability() -> HelperServiceAvailability {
    switch service.status {
    case .notRegistered:
      return .notRegistered
    case .enabled:
      return .enabled
    case .requiresApproval:
      return .approvalRequired
    case .notFound:
      return .notFound
    @unknown default:
      return .notFound
    }
  }

  private func confirmAndRegisterHelper() {
    let alert = NSAlert()
    alert.messageText = "Enable the Lidless safety helper?"
    alert.informativeText =
      "macOS installs the signed Lidless helper as a visible Background Item. It owns only the fixed lid-sleep switch and restores it after crashes or a lost 30-second lease."
    alert.addButton(withTitle: "Enable Helper")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }

    do {
      try service.register()
      AppLog.helper.notice("Helper registration requested")
    } catch {
      recorder.record("helper.registration_failed")
      showAlert(
        title: "Helper registration failed",
        message: "Move the signed Lidless.app to /Applications and try again."
      )
    }
  }

  private func cleanupLegacyGrantAfterVerifiedRoundTrip() async {
    guard didArmInThisRun,
      !UserDefaults.standard.bool(forKey: Self.legacyCleanupDefaultsKey)
    else {
      return
    }
    do {
      let status = try await helperClient.status()
      guard status.status.state == .inactive, status.observedSleepDisabled == false else {
        return
      }
      let result = try await helperClient.removeRecognizedLegacyGrant()
      UserDefaults.standard.set(true, forKey: Self.legacyCleanupDefaultsKey)
      if result == .manualCleanupRequired {
        showAlert(
          title: "Old permission needs manual cleanup",
          message:
            "Lidless found an edited or unrecognized historical sudoers file. It was left untouched. Remove only the Lidless/keepawake entry manually after reviewing it."
        )
      }
    } catch {
      recorder.record("helper.legacy_cleanup_failed")
    }
  }

  private func showAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}
