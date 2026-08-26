import AppKit
import LidlessCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UpdateReporting {
  private static let helperPlistName = "lv.ykv.lidless.helper.plist"
  private static let floorDefaultsKey = "BatteryFloor"
  private static let legacyCleanupDefaultsKey = "LegacyGrantCleanupAttemptedV1"

  private let service = SMAppService.daemon(plistName: helperPlistName)
  private let battery = IOKitBatteryMonitor()
  private let activity = ProcessActivityManager()
  private let scheduler = CommonModeRenewalScheduler()
  private let recorder = DiagnosticRecorder()
  private lazy var notifier = AppSafetyNotifier(recorder: recorder)
  private let launchCleanupRequest: UpdateLaunchCleanupRequest?

  private var helperClient: XPCScheduledHelperClient!
  private var coordinator: SafetyCoordinator!
  private var appUpdateCoordinator: UpdateCoordinator!
  private var releaseChecker: GitHubReleaseChecker!
  private var statusItem: NSStatusItem!
  private let menu = NSMenu()
  private let statusMenuItem = NSMenuItem(
    title: "Checking safety state…", action: nil, keyEquivalent: "")
  private let toggleMenuItem = NSMenuItem(title: "Keep Mac Awake", action: nil, keyEquivalent: "")
  private let setupMenuItem = NSMenuItem(title: "Finish Setup…", action: nil, keyEquivalent: "")
  private let restoreMenuItem = NSMenuItem(
    title: "Restore Normal Lid Sleep…",
    action: nil,
    keyEquivalent: ""
  )
  private let updatesMenuItem = NSMenuItem(
    title: "Check for Updates…", action: nil, keyEquivalent: ""
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
  private var pendingRelease: ReleaseDescriptor?
  private var updateInFlight = false
  private var updateCleanupObserver: NSObjectProtocol?
  #if DEBUG
    private var smokeObserver: NSObjectProtocol?
  #endif

  init(launchCleanupRequest: UpdateLaunchCleanupRequest? = nil) {
    self.launchCleanupRequest = launchCleanupRequest
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    configureHelperStack()
    buildMenu()
    installUpdateCleanupObserverIfNeeded()
    notifier.onEvent = { [weak self] in
      Task { @MainActor [weak self] in
        await self?.refreshState()
      }
    }
    notifier.requestAuthorization()
    startStatusRefresh()
    #if DEBUG
      installSmokeObserver()
    #endif
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

  func applicationWillTerminate(_ notification: Notification) {
    if let updateCleanupObserver {
      DistributedNotificationCenter.default().removeObserver(updateCleanupObserver)
    }
    #if DEBUG
      if let smokeObserver {
        DistributedNotificationCenter.default().removeObserver(smokeObserver)
      }
    #endif
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
              "Normal lid sleep was left unchanged. Check Lidless setup and the battery cutoff."
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
        title: "Lidless installation is incomplete",
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

  @objc private func checkForUpdates() {
    guard !updateInFlight else { return }
    if let pendingRelease {
      confirmAndInstall(pendingRelease)
      return
    }

    updateInFlight = true
    updatesMenuItem.title = "Checking for Updates…"
    updatesMenuItem.isEnabled = false
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let release = try await releaseChecker.latest()
        let installed = try installedVersion()
        if release.version > installed {
          pendingRelease = release
          updateInFlight = false
          updatesMenuItem.title = "Install Lidless \(release.version)…"
          updatesMenuItem.isEnabled = true
          confirmAndInstall(release)
        } else {
          updateInFlight = false
          updatesMenuItem.title = "Check for Updates…"
          updatesMenuItem.isEnabled = true
          showAlert(
            title: "Lidless is up to date",
            message: "You already have the latest version (\(installed))."
          )
        }
      } catch {
        updateInFlight = false
        updatesMenuItem.title = "Check for Updates…"
        updatesMenuItem.isEnabled = true
        recorder.record("update.check_failed")
        showAlert(
          title: "Could not check for updates",
          message: "Lidless could not verify the latest GitHub release. Try again later."
        )
      }
    }
  }

  @objc private func uninstallHelper() {
    let alert = NSAlert()
    alert.messageText = "Remove Lidless from Background Items?"
    alert.informativeText =
      "Lidless will first restore normal lid sleep, clean up a recognized old permission, and remove its background access."
    alert.addButton(withTitle: "Remove")
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
        title: outcome.succeeded ? "Background access removed" : "Removal needs attention",
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
    configureUpdaterStack()

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
    let icon = makeSparkleImage(on: false)
    icon.accessibilityDescription = "Normal lid sleep"
    statusItem.button?.image = icon
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

    updatesMenuItem.target = self
    updatesMenuItem.action = #selector(checkForUpdates)
    menu.addItem(updatesMenuItem)

    let uninstall = NSMenuItem(
      title: "Remove Background Access…",
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
      statusMenuItem.title = "Setup required"
    case .helperApprovalRequired:
      active = false
      statusMenuItem.title = "Approval required in System Settings"
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
      ? "Allow Lidless in System Settings…" : "Finish Setup…"
    restoreMenuItem.isHidden = currentState != .externalKeepAwake

    let icon = makeSparkleImage(on: active)
    icon.accessibilityDescription = active ? "Awake with lid closed" : "Normal lid sleep"
    statusItem.button?.image = icon
    updateFloorMenuChecks()
  }

  private func makeSparkleImage(on: Bool) -> NSImage {
    let size: CGFloat = 18
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    if let context = NSGraphicsContext.current?.cgContext {
      let scale = (size - 2) / 116.0
      func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: (x - 42) * scale + 1, y: (158 - y) * scale + 1)
      }

      let path = CGMutablePath()
      path.move(to: point(100, 42))
      path.addQuadCurve(to: point(158, 100), control: point(116.81, 83.19))
      path.addQuadCurve(to: point(100, 158), control: point(116.81, 116.81))
      path.addQuadCurve(to: point(42, 100), control: point(83.19, 116.81))
      path.addQuadCurve(to: point(100, 42), control: point(83.19, 83.19))
      path.closeSubpath()
      context.addPath(path)
      (on ? NSColor.systemYellow : NSColor.black).setFill()
      context.fillPath()
    }
    image.unlockFocus()
    image.isTemplate = !on
    return image
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

  private func configureUpdaterStack() {
    let downloader = BoundedDownloader()
    let hasher = SHA256FileHasher()
    let validator = StaticCodeValidator()
    let replacer = AtomicAppReplacer(validator: validator, hasher: hasher)
    releaseChecker = GitHubReleaseChecker(downloader: downloader)
    appUpdateCoordinator = UpdateCoordinator(
      downloader: downloader,
      hasher: hasher,
      stager: UpdateStager(),
      validator: validator,
      replacer: replacer,
      helper: AppUpdateHelperController(safetyCoordinator: coordinator, client: helperClient),
      launcher: UpdatedAppLauncher(),
      reporter: self
    )
  }

  private func installedVersion() throws -> SemanticVersion {
    guard
      let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    else {
      throw SemanticVersionError.invalid
    }
    return try SemanticVersion(raw)
  }

  private func confirmAndInstall(_ release: ReleaseDescriptor) {
    let alert = NSAlert()
    alert.messageText = "Install Lidless \(release.version)?"
    alert.informativeText =
      "Lidless will verify the checksum, Apple signature, and Gatekeeper approval before replacing the app. Normal lid sleep is restored before the final swap."
    alert.addButton(withTitle: "Install")
    alert.addButton(withTitle: "Later")
    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }

    pendingRelease = nil
    updateInFlight = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await appUpdateCoordinator.install(release, installedApp: Bundle.main.bundleURL)
      } catch {
        updateInFlight = false
        recorder.record("update.install_failed")
      }
    }
  }

  func updatePhaseChanged(_ phase: UpdatePhase) {
    switch phase {
    case .checking:
      updatesMenuItem.title = "Preparing Update…"
      updatesMenuItem.isEnabled = false
    case .downloading(let version):
      updatesMenuItem.title = "Downloading \(version)…"
      updatesMenuItem.isEnabled = false
    case .verifying:
      updatesMenuItem.title = "Verifying Update…"
      updatesMenuItem.isEnabled = false
    case .mounting:
      updatesMenuItem.title = "Opening Verified Update…"
      updatesMenuItem.isEnabled = false
    case .preparing:
      updatesMenuItem.title = "Preparing Installation…"
      updatesMenuItem.isEnabled = false
    case .installing:
      updatesMenuItem.title = "Installing Update…"
      updatesMenuItem.isEnabled = false
    case .manualInstall(let diskImage):
      updateInFlight = false
      updatesMenuItem.title = "Check for Updates…"
      updatesMenuItem.isEnabled = true
      NSWorkspace.shared.activateFileViewerSelecting([diskImage])
      showAlert(
        title: "Update ready in Downloads",
        message: "Open the verified disk image and drag Lidless to Applications."
      )
    case .finished(let version):
      updatesMenuItem.title = "Updated to \(version)"
      stopStatusRefresh()
      terminationApproved = true
      NSApp.terminate(nil)
    case .failed(let code):
      updateInFlight = false
      updatesMenuItem.title = "Update Failed — \(code)"
      updatesMenuItem.isEnabled = true
      showAlert(
        title: "Lidless update stopped safely",
        message:
          "The update failed during \(code). The installed app was left unchanged or rolled back."
      )
    }
  }

  private func installUpdateCleanupObserverIfNeeded() {
    guard let launchCleanupRequest else { return }
    updateCleanupObserver = DistributedNotificationCenter.default().addObserver(
      forName: UpdateLaunchConfirmation.name,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let receivedToken =
          notification.userInfo?[UpdateLaunchConfirmation.tokenKey] as? String
      else {
        return
      }
      Task { @MainActor [weak self] in
        guard let self,
          receivedToken == launchCleanupRequest.token
        else {
          return
        }
        if let updateCleanupObserver {
          DistributedNotificationCenter.default().removeObserver(updateCleanupObserver)
          self.updateCleanupObserver = nil
        }
        let oldApp = launchCleanupRequest.oldAppSibling
        let installedApp = Bundle.main.bundleURL
        Task { @MainActor [weak self] in
          let cleanupResult = await Task.detached { () -> Result<Void, any Error> in
            do {
              let validator = StaticCodeValidator()
              let replacer = AtomicAppReplacer(
                validator: validator,
                hasher: SHA256FileHasher()
              )
              try replacer.removeOldAppSibling(oldApp, installedApp: installedApp)
              return .success(())
            } catch {
              return .failure(error)
            }
          }.value
          if case .failure = cleanupResult {
            self?.recorder.record("update.old_cleanup_failed")
          }
        }
      }
    }
  }

  private func confirmAndRegisterHelper() {
    let alert = NSAlert()
    alert.messageText = "Allow Lidless to run in the background?"
    alert.informativeText =
      "This lets Lidless control lid sleep and automatically restore normal sleep if the app closes or stops responding. macOS will show Lidless under Background Items."
    alert.addButton(withTitle: "Continue")
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
        title: "Setup failed",
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

  #if DEBUG
    private func installSmokeObserver() {
      smokeObserver = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("lv.ykv.lidless.debug.smoke"),
        object: nil,
        queue: .main
      ) { [weak self] notification in
        let command = notification.userInfo?["command"] as? String
        let percentage = notification.userInfo?["percentage"] as? Int
        Task { @MainActor [weak self] in
          await self?.handleSmokeCommand(command, percentage: percentage)
        }
      }
    }

    private func handleSmokeCommand(_ command: String?, percentage: Int?) async {
      switch command {
      case "arm":
        if let smokeFloor = BatteryFloor(10) {
          try? await coordinator.arm(floor: smokeFloor)
        }
      case "disarm":
        await coordinator.disarm(reason: .user)
      case "battery":
        battery.setSmokeBatteryPercentage(percentage)
        await coordinator.powerDidChange()
      case "clear-battery":
        battery.setSmokeBatteryPercentage(nil)
      case "quit":
        NSApp.terminate(nil)
      case "invalid-version":
        do {
          _ = try PowerSampleMessage(
            validatingVersion: 2,
            sourceRaw: PowerSource.battery.rawValue,
            percentage: 80,
            sampledAt: Date(),
            floor: 10
          )
          recorder.record("debug.invalid_version_accepted")
        } catch {
          recorder.record("debug.invalid_version_rejected")
        }
      default:
        recorder.record("debug.unknown_smoke_command")
      }
      await refreshState()
    }
  #endif
}
