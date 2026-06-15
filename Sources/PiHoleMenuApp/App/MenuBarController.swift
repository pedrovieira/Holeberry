import AppKit
import Combine
import OSLog

@MainActor
final class MenuBarController: NSObject {
  private let statusItem: NSStatusItem
  private let timerManager = TimerManager()
  private let serverManager = PiholeServerManager()
  private let reachability = ReachabilityMonitor()
  private let tempUnblockManager: TempUnblockManager
  private lazy var menuBuilder: MenuBuilder = {
    let builder = MenuBuilder(serverManager: serverManager, timerManager: timerManager)
    builder.onDisableURL = { [weak self] domain, duration in
      self?.performTempUnblock(domain: domain, duration: duration)
    }
    builder.onReBlockDomain = { [weak self] uuid in
      self?.performReblock(uuid: uuid)
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

  init(tempUnblockManager: TempUnblockManager = .shared) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    self.tempUnblockManager = tempUnblockManager
    super.init()
    configureStatusItem()
    observeTimer()
    pollInitialStatus()
    listenForSettingsChanges()
    setupReachability()
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

    let settings = SettingsStore()
    let menu = menuBuilder.buildMenu(
      recentBlocked: recentBlockedCache,
      error: errorMessage,
      isConnected: reachability.isConnected,
      activeRecords: tempUnblockManager.activeRecords,
      maxUnblocks: settings.maxActiveUnblocks
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
    NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
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
        let blocked = try await serverManager.perform(for: server) { service in
          try await service.getRecentBlocked()
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
    let cap = SettingsStore().maxActiveUnblocks
    guard tempUnblockManager.activeRecords.count < cap else {
      showError("Maximum active unblocks reached (\(cap))")
      return
    }

    guard let server = serverManager.servers.first, server.version != nil else {
      showError("No configured Pi-hole instance")
      return
    }

    Task {
      do {
        try await serverManager.perform(for: server) { service in
          try await tempUnblockManager.add(domain: domain, duration: duration, service: service)
        }
        setError(nil)
      } catch {
        showError("Failed to unblock \(domain): \(error.localizedDescription)")
      }
    }
  }

  private func performReblock(uuid: String) {
    guard let record = tempUnblockManager.activeRecords.first(where: { $0.uuid == uuid }) else {
      return
    }
    guard let server = serverManager.servers.first, server.version != nil else {
      showError("No configured Pi-hole instance")
      return
    }

    Task {
      do {
        try await serverManager.perform(for: server) { service in
          try await service.deleteDomain(domain: record.domain)
        }
        tempUnblockManager.remove(record: record)
        setError(nil)
      } catch {
        showError("Failed to re-block \(record.domain): \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Inline Error

  private func showError(_ message: String) {
    setError(message)
    errorClearTask?.cancel()
    errorClearTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      self?.setError(nil)
    }
  }

  private func setError(_ message: String?) {
    errorMessage = message
  }

  // MARK: - Countdown Timer

  private func startCountdownTimer() {
    stopCountdownTimer()
    countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      guard let self, let menu = self.currentMenu else { return }
      self.menuBuilder.updateCountdowns(in: menu)
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
