import AppKit
import Combine
import Defaults
import HoleberryCore
import OSLog
import Sparkle

@MainActor
final class MenuBarController: NSObject {
  private let statusItem: NSStatusItem
  private let timerManager: TimerManager
  private let serverManager: PiholeServerManager
  private let reachability: ReachabilityMonitor
  private let statusMonitor: ServerStatusPoller
  private let browserTabCoordinator: BrowserTabCoordinator
  private let localIPAddressResolver: any LocalIPAddressProviding
  private let updater: SPUUpdater
  private let notificationCoordinator: NotificationCoordinator
  private let defaultsSuite: UserDefaults
  private let settingsWindowController: SettingsWindowController
  private let menuBuilder = MenuBuilder()

  private var cancellables = Set<AnyCancellable>()
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "menu-bar")

  // Menu lifecycle
  private var currentMenu: NSMenu?

  // Browser icon cache
  private var appIconCache: [String: NSImage] = [:]

  // MARK: - Countdown view

  private lazy var statusItemButton: StatusItemButton = {
    let view = StatusItemButton()
    view.onClick = { [weak self] in
      self?.handleClick()
    }
    return view
  }()

  init(
    timerManager: TimerManager,
    serverManager: PiholeServerManager,
    reachability: ReachabilityMonitor,
    statusMonitor: ServerStatusPoller,
    browserTabCoordinator: BrowserTabCoordinator,
    localIPAddressResolver: any LocalIPAddressProviding,
    updater: SPUUpdater,
    notificationCoordinator: NotificationCoordinator,
    defaultsSuite: UserDefaults = .standard,
    settingsWindowController: SettingsWindowController
  ) {
    self.timerManager = timerManager
    self.serverManager = serverManager
    self.reachability = reachability
    self.statusMonitor = statusMonitor
    self.browserTabCoordinator = browserTabCoordinator
    self.localIPAddressResolver = localIPAddressResolver
    self.updater = updater
    self.notificationCoordinator = notificationCoordinator
    self.defaultsSuite = defaultsSuite
    self.settingsWindowController = settingsWindowController

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    super.init()

    configureStatusItem()
    observeTimer()
    pollInitialStatus()
    setupReachability()
  }

  // MARK: - Status Item

  private func configureStatusItem() {
    guard let button = statusItem.button else { return }
    let image = NSImage(named: "StatusBar")
    image?.size = NSSize(width: 17, height: 17)
    button.image = image
    button.image?.isTemplate = true
    button.action = #selector(handleClick)
    button.target = self
  }


  // swiftlint:disable:next function_body_length
  @objc private func handleClick() {
    // Refresh data in the background for next time, but show the menu now with cached data
    statusMonitor.pollNow()

    let browserTabStatus = browserTabCoordinator.resolve()
    let browserIcon = browserTabStatus.browser.flatMap { resolveBrowserIcon(for: $0) }

    let gravityState: GravityMenuState
    if !Defaults[.showGravityMenuItem(suite: defaultsSuite)] {
      gravityState = .hidden
    } else if statusMonitor.isGravityUpdating {
      gravityState = .updating
    } else {
      gravityState = .ready(completedAt: statusMonitor.gravityCompletedAt)
    }

    let menu = menuBuilder.buildMenu(
      actions: MenuActions(
        openAppSettings: { [settingsWindowController] in settingsWindowController.showWindow() },
        checkForUpdates: { [updater] in updater.checkForUpdates() },
        disableBlocking: { [serverManager, statusMonitor] duration in
          guard !serverManager.servers.isEmpty else { return }
          Task {
            await statusMonitor.applyBlockingChange(enabled: false, duration: duration)
          }
        },
        reEnableBlocking: { [statusMonitor] in
          Task {
            await statusMonitor.applyBlockingChange(enabled: true, duration: nil)
          }
        },
        triggerGravityUpdate: { [weak self, statusMonitor] in
          Task {
            let outcomes = await statusMonitor.applyGravityUpdate()
            self?.handleGravityOutcomes(outcomes)
          }
        },
        disableURL: { [weak self] domain, duration in
          self?.performTempUnblock(domain: domain, duration: duration)
        },
        addToAllowlist: { [weak self] domain in
          self?.addToAllowlist(domain: domain)
        },
        enableBrowserPermission: { [weak self] in
          self?.handleEnableBrowserPermission()
        },
        openAutomationSettings: {
          if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Automation") {
            NSWorkspace.shared.open(url)
          }
        }
      ),
      isTimerDisabled: timerManager.isRunning,
      recentBlockedProvider: { [statusMonitor] in statusMonitor.recentBlocked },
      userIP: localIPAddressResolver.localIPAddress(),
      showAllClients: Defaults[.showAllClientsRecentBlocked(suite: defaultsSuite)],
      showPerInstanceStats: Defaults[.showPerInstanceStats(suite: defaultsSuite)],
      durations: Defaults[.unblockDurations(suite: defaultsSuite)],
      isConnected: reachability.isConnected,
      connectionStatuses: statusMonitor.connectionStatuses,
      blockingStatuses: statusMonitor.blockingStatuses,
      gravityState: gravityState,
      querySummaries: statusMonitor.querySummaries,
      servers: serverManager.servers,
      browserTabStatus: browserTabStatus,
      browserIcon: browserIcon
    )
    menu.delegate = self
    currentMenu = menu
    statusItem.menu = menu

    if let button = statusItem.button, statusItemButton.superview === button {
      menu.popUp(
        positioning: nil,
        at: NSPoint(x: 0, y: button.bounds.height),
        in: button
      )
    } else {
      statusItem.button?.performClick(nil)
    }
  }

  // MARK: - Timer Observation

  private func observeTimer() {
    timerManager.$isRunning
      .combineLatest(timerManager.$remainingSeconds, timerManager.$totalDuration)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] isRunning, remaining, totalDuration in
        self?.updateDisplay(
          isRunning: isRunning,
          remaining: remaining,
          totalDuration: totalDuration
        )
      }
      .store(in: &cancellables)
  }

  private func ensureCustomViewIsShowing() {
    guard let button = statusItem.button else { return }
    guard statusItemButton.superview !== button else { return }
    button.image = nil
    button.title = ""
    statusItemButton.frame = button.bounds
    statusItemButton.autoresizingMask = [.width, .height]
    button.addSubview(statusItemButton)
  }

  private func animatePillWidth(to width: CGFloat) {
    let current = statusItem.length
    guard abs(current - width) > 0.5 else { return }
    statusItem.length = width
  }

  private func updateDisplay(isRunning: Bool, remaining: TimeInterval, totalDuration: TimeInterval?) {
    if isRunning && remaining > 0 {
      // Timed countdown — use custom view
      ensureCustomViewIsShowing()
      statusItemButton.update(
        remainingSeconds: remaining,
        totalDuration: totalDuration,
        formattedTime: timerManager.formattedTime
      )
      animatePillWidth(to: statusItemButton.preferredWidth)
      statusItemButton.setAccessibilityLabel(
        "Pi-hole disabled, \(timerManager.formattedTime) remaining"
      )
    } else if isRunning {
      // Indefinite — use custom view with "∞"
      ensureCustomViewIsShowing()
      statusItemButton.update(
        remainingSeconds: 0,
        totalDuration: nil as TimeInterval?,
        formattedTime: "\u{221E}"
      )
      animatePillWidth(to: statusItemButton.preferredWidth)
      statusItemButton.setAccessibilityLabel("Pi-hole disabled indefinitely")
    } else {
      // Blocking active — revert to normal button
      if statusItemButton.superview != nil {
        statusItemButton.removeFromSuperview()
        statusItem.length = NSStatusItem.variableLength
      }
      guard let button = statusItem.button else { return }
      configureStatusItem()
      button.title = ""
      button.setAccessibilityLabel("Pi-hole blocking active")
    }
  }

  // MARK: - Initial Status

  private func pollInitialStatus() {
    guard let server = serverManager.servers.first else { return }
    Task {
      let statuses = await serverManager.getBlockingStatus()
      if case .success(let status) = statuses[server.id] {
        switch status {
        case .enabled:
          timerManager.cancel()
        case .disabled(let remaining):
          if let remaining, remaining > 0 {
            timerManager.start(duration: remaining)
          } else {
            timerManager.start(duration: nil)
          }
        }
      }
    }
  }

  // MARK: - Reachability

  private func setupReachability() {
    reachability.onConnect = { [weak self] in
      Task { self?.statusMonitor.pollNow() }
    }
  }

  // MARK: - Temp Unblock

  private func performTempUnblock(domain: String, duration: TimeInterval) {
    Task {
      do {
        try await serverManager.unblock(domain: domain, duration: duration)
      } catch {
        notificationCoordinator.schedule(
          .unblockFailed(domain: domain, error: error.localizedDescription)
        )
      }
    }
  }

  // MARK: - Gravity

  private func handleGravityOutcomes(_ outcomes: [UUID: GravityUpdateOutcome]) {
    notificationCoordinator.scheduleGravityOutcomeNotifications(outcomes) { [serverManager] id in
      serverManager.servers.first { $0.id == id }?.label
    }
  }

  // MARK: - Add to Allowlist

  private func addToAllowlist(domain: String) {
    Task {
      await serverManager.addToAllowlist(domain: domain)
    }
  }

  /// Returns the browser tab status for menu rendering.
  func resolveBrowserTabStatus() -> ResolvedBrowserTab {
    browserTabCoordinator.resolve()
  }

  // MARK: - Browser Icon

  private func resolveBrowserIcon(for browser: Browser) -> NSImage? {
    let bundleID = browser.bundleID
    if let cached = appIconCache[bundleID] {
      return cached
    }

    guard
      let app = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleID
      ).first,
      let icon = app.resizedIcon(size: NSRunningApplication.menuBarIconSize)
    else { return nil }
    appIconCache[bundleID] = icon
    return icon
  }

  // MARK: - Enable Browser Permission

  private func handleEnableBrowserPermission() {
    _ = browserTabCoordinator.requestPermissionIfNeededAndResolve()
    // Rebuild the menu to show updated state
    handleClick()
  }

  // MARK: - Check for Updates

  @objc private func checkForUpdates() {
    updater.checkForUpdates()
  }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
  func menuDidClose(_ menu: NSMenu) {
    currentMenu = nil
    statusItem.menu = nil
  }
}
