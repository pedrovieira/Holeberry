import AppKit
import Combine
import Defaults
import OSLog
import UserNotifications

@MainActor
final class MenuBarController: NSObject {
  private let statusItem: NSStatusItem
  private let timerManager = TimerManager()
  private let serverManager = PiholeServerManager.shared
  private let reachability = ReachabilityMonitor()
  private let statusMonitor = ServerStatusMonitor.shared
  private let browserUrlFetcher = BrowserUrlFetcher()
  private lazy var menuBuilder: MenuBuilder = {
    let builder = MenuBuilder(
      serverManager: serverManager,
      timerManager: timerManager
    )
    builder.onDisableURL = { [weak self] domain, duration in
      self?.performTempUnblock(domain: domain, duration: duration)
    }
    builder.onAddToAllowlist = { [weak self] domain in
      self?.addToAllowlist(domain: domain)
    }
    builder.onUnblockCurrentTab = { [weak self] in
      self?.performBrowserTabUnblock()
    }

    return builder
  }()

  private var cancellables = Set<AnyCancellable>()
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "menu-bar")

  // Recent blocked cache
  private var recentBlockedCache: [String] = []
  private var lastCacheRefresh = Date.distantPast
  private let cacheTTL: TimeInterval = 60

  // Menu lifecycle
  private var currentMenu: NSMenu?

  // Inline error
  private var errorMessage: String?
  private var errorClearTask: Task<Void, Never>?

  // Browser icon cache
  private var appIconCache: [String: NSImage] = [:]

  override init() {
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
    button.image = NSImage(systemSymbolName: "shield.fill", accessibilityDescription: "Pi-hole Active")
    button.action = #selector(handleClick)
    button.target = self
  }

  @objc private func handleClick() {
    ensureCacheFresh()

    let browserTabStatus = browserUrlFetcher.resolveCurrentTabDomain()
    var browserIcon: NSImage?
    if case .url = browserTabStatus {
      browserIcon = resolveBrowserIcon()
    }
    let menu = menuBuilder.buildMenu(
      recentBlocked: recentBlockedCache,
      error: errorMessage,
      isConnected: reachability.isConnected,
      combinedStatus: statusMonitor.combinedStatus,
      connectionStatuses: statusMonitor.connectionStatuses,
      blockingStatuses: statusMonitor.blockingStatuses,
      servers: statusMonitor.servers,
      browserTabStatus: browserTabStatus,
      browserIcon: browserIcon
    )
    menu.delegate = self
    currentMenu = menu
    statusItem.menu = menu

    statusItem.button?.performClick(nil)
  }

  // MARK: - Timer Observation

  private func observeTimer() {
    timerManager.$isDisabled
      .combineLatest(timerManager.$remainingSeconds)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] isDisabled, remaining in
        self?.updateDisplay(isDisabled: isDisabled, remaining: remaining)
      }
      .store(in: &cancellables)
  }

  private func updateDisplay(isDisabled: Bool, remaining: TimeInterval) {
    guard let button = statusItem.button else { return }
    if isDisabled && remaining > 0 {
      button.title = timerManager.formattedTime
      button.image = NSImage(
        systemSymbolName: "shield.slash.fill", accessibilityDescription: "Pi-hole Disabled"
      )
      button.setAccessibilityLabel("Pi-hole disabled, \(timerManager.formattedTime) remaining")
    } else if isDisabled {
      button.title = "∞"
      button.image = NSImage(
        systemSymbolName: "shield.slash.fill", accessibilityDescription: "Pi-hole Disabled Indefinitely"
      )
      button.setAccessibilityLabel("Pi-hole disabled indefinitely")
    } else {
      button.title = ""
      button.image = NSImage(systemSymbolName: "shield.fill", accessibilityDescription: "Pi-hole Active")
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
      forName: .authManagerTotpRequired,
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
        let length = max(Defaults[.recentBlockedCount], 20)
        let blocked = try await serverManager.getRecentBlocked(count: length)
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

  // MARK: - Browser Tab Unblock

  private func performBrowserTabUnblock() {
    let status = browserUrlFetcher.resolveCurrentTabDomain()
    guard case .url(let domain) = status else {
      logger.warning("Browser tab unblock failed: \(String(describing: status))")
      return
    }
    Task {
      do {
        try await serverManager.unblock(domain: domain, duration: 300)
        setError(nil)
      } catch {
        showError("Failed to unblock \(domain): \(error.localizedDescription)")
      }
    }
  }

  /// Returns the browser tab status for menu rendering.
  func resolveBrowserTabStatus() -> BrowserUrlFetcher.Status {
    browserUrlFetcher.resolveCurrentTabDomain()
  }

  // MARK: - Browser Icon

  private func resolveBrowserIcon() -> NSImage? {
    guard let app = NSWorkspace.shared.frontmostApplication,
      let bundleID = app.bundleIdentifier
    else { return nil }

    if let cached = appIconCache[bundleID] {
      return cached
    }
    guard let icon = app.resizedIcon(size: NSRunningApplication.menuBarIconSize) else { return nil }
    appIconCache[bundleID] = icon
    return icon
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
