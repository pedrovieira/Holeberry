import AppKit
import Combine
import Defaults
import OSLog
import Sparkle
import UserNotifications

@MainActor
final class MenuBarController: NSObject {
  private let statusItem: NSStatusItem
  private let timerManager: TimerManager
  private let serverManager: PiholeServerManager
  private let reachability: ReachabilityMonitor
  private let statusMonitor: ServerStatusMonitor
  private let browserTabCoordinator: BrowserTabCoordinator
  private let localIPAddressResolver: LocalIPAddressProviding
  private let updater: SPUUpdater
  private lazy var menuBuilder: MenuBuilder = {
    let builder = MenuBuilder(
      serverManager: serverManager,
      timerManager: timerManager,
      updater: updater
    )
    builder.onDisableURL = { [weak self] domain, duration in
      self?.performTempUnblock(domain: domain, duration: duration)
    }
    builder.onAddToAllowlist = { [weak self] domain in
      self?.addToAllowlist(domain: domain)
    }
    builder.onEnableBrowserPermission = { [weak self] in
      self?.handleEnableBrowserPermission()
    }
    builder.onOpenAutomationSettings = { [weak self] in
      if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Automation") {
        NSWorkspace.shared.open(url)
      }
    }

    return builder
  }()

  private var cancellables = Set<AnyCancellable>()
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "menu-bar")

  // Recent blocked cache
  private var recentBlockedCache: [BlockedDomain] = []
  private var lastCacheRefresh = Date.distantPast
  private let cacheTTL: TimeInterval = 60

  // Menu lifecycle
  private var currentMenu: NSMenu?

  // Inline error
  private var errorMessage: String?
  private var errorClearTask: Task<Void, Never>?

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
    statusMonitor: ServerStatusMonitor,
    browserTabCoordinator: BrowserTabCoordinator,
    localIPAddressResolver: LocalIPAddressProviding = LocalIPAddressResolver(),
    updater: SPUUpdater
  ) {
    self.timerManager = timerManager
    self.serverManager = serverManager
    self.reachability = reachability
    self.statusMonitor = statusMonitor
    self.browserTabCoordinator = browserTabCoordinator
    self.localIPAddressResolver = localIPAddressResolver
    self.updater = updater
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    configureStatusItem()
    observeTimer()
    pollInitialStatus()
    setupReachability()
    observeTotpNotifications()
    prewarmRecentBlockedCache()
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

  @objc private func handleClick() {
    ensureCacheFresh()

    let browserTabStatus = browserTabCoordinator.resolve()
    var browserIcon: NSImage?
    if case .url = browserTabStatus {
      browserIcon = browserTabCoordinator.resolveBrowserIcon()
    } else if case .permissionNeeded = browserTabStatus {
      browserIcon = browserTabCoordinator.resolveBrowserIcon()
    } else if case .permissionDenied = browserTabStatus {
      browserIcon = browserTabCoordinator.resolveBrowserIcon()
    }
    let menu = menuBuilder.buildMenu(
      recentBlocked: recentBlockedCache,
      userIP: localIPAddressResolver.localIPAddress(),
      showAllClients: Defaults[.showAllClientsRecentBlocked()],
      error: errorMessage,
      isConnected: reachability.isConnected,
      connectionStatuses: statusMonitor.connectionStatuses,
      blockingStatuses: statusMonitor.blockingStatuses,
      querySummaries: statusMonitor.querySummaries,
      servers: statusMonitor.servers,
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
    timerManager.$isDisabled
      .combineLatest(timerManager.$remainingSeconds, timerManager.$totalDuration)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] isDisabled, remaining, totalDuration in
        self?.updateDisplay(
          isDisabled: isDisabled,
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

  private func updateDisplay(isDisabled: Bool, remaining: TimeInterval, totalDuration: TimeInterval?) {
    if isDisabled && remaining > 0 {
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
    } else if isDisabled {
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
      do {
        let status = try await serverManager.getBlockingStatus(for: server.id)
        timerManager.syncFromRemote(status)
      } catch {
        logger.warning("Initial status poll failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  // MARK: - Reachability

  private func setupReachability() {
    reachability.onConnect = { [weak self] in
      self?.refreshRecentBlockedCache()
    }
  }

  // MARK: - TOTP Notifications

  private func observeTotpNotifications() {
    NotificationCenter.default.addObserver(
      forName: .v6SessionTotpRequired,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self else { return }
      let serverHost: String
      let serverURL = notification.userInfo?["serverURL"] as? String
      let extractedHost = serverURL.flatMap { URL(string: $0)?.host }
      if let extractedHost {
        serverHost = extractedHost
      } else {
        serverHost = "your Pi-hole"
      }
      Task { @MainActor in
        self.showError("TOTP required — update credential in Settings", persistent: true)
        self.sendTotpUserNotification(host: serverHost)
      }
    }
  }

  private func sendTotpUserNotification(host: String) {
    let content = UNMutableNotificationContent()
    content.title = "Holeberry"
    content.body = "TOTP is required for \(host). Open Settings and use an Application Password."
    content.sound = .default
    content.categoryIdentifier = "SHORTCUT_ERROR"

    let request = UNNotificationRequest(
      identifier: "totp-required-\(host)",
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request) { error in
      if let error {
        self.logger.warning("Failed to deliver TOTP notification: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  // MARK: - Recent Blocked Cache

  private func prewarmRecentBlockedCache() {
    refreshRecentBlockedCache()
  }

  private func ensureCacheFresh() {
    let elapsed = Date().timeIntervalSince(lastCacheRefresh)
    if elapsed > cacheTTL {
      refreshRecentBlockedCache()
    }
  }

  private func refreshRecentBlockedCache() {
    guard serverManager.servers.first != nil else {
      recentBlockedCache = []
      lastCacheRefresh = Date()
      return
    }
    Task {
      do {
        let clientIP = localIPAddressResolver.localIPAddress()
        let showAll = Defaults[.showAllClientsRecentBlocked()]
        let interval = DateInterval(
          start: Date().addingTimeInterval(-3600),
          end: Date())
        let blocked = try await serverManager.getRecentBlocked(
          forClientIp: showAll ? nil : clientIP, interval: interval)
        recentBlockedCache = blocked
        lastCacheRefresh = Date()
      } catch {
        logger.warning("Failed to refresh recent blocked cache: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  // MARK: - Temp Unblock

  private func performTempUnblock(domain: String, duration: TimeInterval) {
    Task {
      do {
        try await serverManager.unblock(domain: domain, duration: duration)
        setError(nil)
      } catch {
        showError("Failed to unblock \(domain): \(error.localizedDescription)")
      }
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

  // MARK: - Enable Browser Permission

  private func handleEnableBrowserPermission() {
    _ = browserTabCoordinator.requestPermissionAndResolve()
    // Rebuild the menu to show updated state
    handleClick()
  }

  // MARK: - Check for Updates

  @objc private func checkForUpdates() {
    updater.checkForUpdates()
  }

  // MARK: - Inline Error

  private func showError(_ message: String, persistent: Bool = false) {
    setError(message, persistent: persistent)
  }

  private func setError(_ message: String?, persistent: Bool = false) {
    errorMessage = message
    errorClearTask?.cancel()
    if !persistent, message != nil {
      errorClearTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(3))
        self?.setError(nil)
      }
    }
  }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
  func menuDidClose(_ menu: NSMenu) {
    currentMenu = nil
    statusItem.menu = nil
  }
}
