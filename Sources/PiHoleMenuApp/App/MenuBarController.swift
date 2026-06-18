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
  private let tempUnblockManager: TempUnblockManager
  private lazy var menuBuilder: MenuBuilder = {
    let builder = MenuBuilder(
      serverManager: serverManager,
      timerManager: timerManager,
      tempUnblockManager: tempUnblockManager
    )
    builder.onDisableURL = { [weak self] domain, duration in
      self?.performTempUnblock(domain: domain, duration: duration)
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
  private var countdownTimer: Timer?

  // Inline error
  private var errorMessage: String?
  private var errorClearTask: Task<Void, Never>?

  init(tempUnblockManager: TempUnblockManager) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    self.tempUnblockManager = tempUnblockManager
    super.init()
    configureStatusItem()
    observeTimer()
    pollInitialStatus()
    listenForSettingsChanges()
    setupReachability()
    observeTotpNotifications()
    prewarmRecentBlockedCache()
    Task {
      await tempUnblockManager.reconcileOnLaunch()
    }
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

    let menu = menuBuilder.buildMenu(
      recentBlocked: recentBlockedCache,
      error: errorMessage,
      isConnected: reachability.isConnected,
      activeRecords: tempUnblockManager.activeRecords
    )
    menu.delegate = self
    currentMenu = menu
    statusItem.menu = menu

    if !tempUnblockManager.activeRecords.isEmpty {
      startCountdownTimer()
    }

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
    } else if isDisabled {
      button.title = "∞"
      button.image = NSImage(
        systemSymbolName: "shield.slash.fill", accessibilityDescription: "Pi-hole Disabled Indefinitely"
      )
    } else {
      button.title = ""
      button.image = NSImage(systemSymbolName: "shield.fill", accessibilityDescription: "Pi-hole Active")
    }
  }

  // MARK: - Initial Status

  private func pollInitialStatus() {
    guard let server = serverManager.servers.first, server.version != nil else { return }
    Task {
      do {
        let status = try await serverManager.getBlockingStatus(for: server)
        timerManager.syncFromRemote(status)
      } catch {
        logger.warning("Initial status poll failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  // MARK: - Settings Changes

  private func listenForSettingsChanges() {
    Defaults.publisher(.servers)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.serverManager.reloadServers()
      }
      .store(in: &cancellables)
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
      if let serverURL = notification.userInfo?["serverURL"] as? String,
         let host = URL(string: serverURL)?.host {
        serverHost = host
      } else {
        serverHost = "your Pi-hole"
      }
      self.showError("TOTP required — update credential in Settings", persistent: true)
      self.sendTotpUserNotification(host: serverHost)
    }
  }

  private func sendTotpUserNotification(host: String) {
    let content = UNMutableNotificationContent()
    content.title = "Pi-hole Menu Bar"
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
    guard let server = serverManager.servers.first, server.version != nil else {
      recentBlockedCache = []
      lastCacheRefresh = Date()
      return
    }
    Task {
      do {
        let length = max(Defaults[.recentBlockedCount], 20)
        let blocked = try await serverManager.perform(for: server) { service in
          try await service.getRecentBlocked(count: length)
        }
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
        _ = try await tempUnblockManager.add(domain: domain, duration: duration)
        setError(nil)
      } catch {
        showError("Failed to unblock \(domain): \(error.localizedDescription)")
      }
    }
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

  // MARK: - Countdown Timer

  private func startCountdownTimer() {
    stopCountdownTimer()
    countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, let menu = self.currentMenu else { return }
        self.menuBuilder.updateCountdowns(in: menu)
      }
    }
    if let countdownTimer { RunLoop.current.add(countdownTimer, forMode: .common) }
  }

  private func stopCountdownTimer() {
    countdownTimer?.invalidate()
    countdownTimer = nil
  }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
  func menuDidClose(_ menu: NSMenu) {
    stopCountdownTimer()
    currentMenu = nil
    statusItem.menu = nil
  }
}
