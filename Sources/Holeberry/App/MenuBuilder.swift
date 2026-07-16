import AppKit
import OSLog
import Sparkle

// swiftlint:disable file_length
// swiftlint:disable type_body_length

@MainActor
final class MenuBuilder: NSObject {
  private let serverManager: PiholeServerManager
  private let timerManager: TimerManager
  private let updater: SPUUpdater
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "menu-builder")

  var onDisableURL: ((String, TimeInterval) -> Void)?
  var onAddToAllowlist: ((String) -> Void)?
  var onEnableBrowserPermission: (() -> Void)?

  // User-device tracking for recently-blocked icon
  private var userIP: String?
  private var showAllClients = false

  init(
    serverManager: PiholeServerManager,
    timerManager: TimerManager,
    updater: SPUUpdater
  ) {
    self.serverManager = serverManager
    self.timerManager = timerManager
    self.updater = updater
  }

  // swiftlint:disable:next function_parameter_count
  func buildMenu(
    recentBlocked: [BlockedDomain],
    userIP: String? = nil,
    showAllClients: Bool = false,
    error: String?,
    isConnected: Bool,
    connectionStatuses: [UUID: ConnectionStatus],
    blockingStatuses: [UUID: BlockingStatus],
    querySummaries: [UUID: QuerySummary],
    servers: [ServerConfig],
    browserTabStatus: ResolvedBrowserTab = .disabled,
    browserIcon: NSImage? = nil
  ) -> NSMenu {
    self.userIP = userIP
    self.showAllClients = showAllClients
    let menu = NSMenu()
    addStatusSection(
      to: menu,
      error: error,
      isConnected: isConnected,
      querySummaries: querySummaries,
      connectionStatuses: connectionStatuses,
      blockingStatuses: blockingStatuses,
      servers: servers
    )
    menu.addItem(.separator())
    addInstancesSection(
      to: menu,
      connectionStatuses: connectionStatuses,
      blockingStatuses: blockingStatuses,
      querySummaries: querySummaries,
      servers: servers
    )
    menu.addItem(.separator())
    addBlockingControls(to: menu, isConnected: isConnected)

    if browserTabStatus != .disabled {
      menu.addItem(.separator())
      addBrowserTabSection(to: menu, browserStatus: browserTabStatus, browserIcon: browserIcon)
    }

    menu.addItem(.separator())
    addRecentlyBlockedSection(
      to: menu, recentBlocked: recentBlocked, isConnected: isConnected
    )
    menu.addItem(.separator())
    addSettingsAndQuit(to: menu)
    return menu
  }

  // swiftlint:disable:next function_parameter_count
  private func addStatusSection(
    to menu: NSMenu,
    error: String?,
    isConnected: Bool,
    querySummaries: [UUID: QuerySummary],
    connectionStatuses: [UUID: ConnectionStatus],
    blockingStatuses: [UUID: BlockingStatus],
    servers: [ServerConfig]
  ) {
    if let error {
      let item = NSMenuItem()
      item.attributedTitle = MenuItemFactory.statusLine(
        dotColor: .systemRed,
        text: "⚠ \(error)"
      )
      item.isEnabled = false
      menu.addItem(item)
    } else if !isConnected {
      let item = NSMenuItem(title: "Disconnected", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    } else if servers.isEmpty {
      let item = NSMenuItem(title: "", action: #selector(openSettings), keyEquivalent: "")
      item.target = self
      item.image = NSImage(
        systemSymbolName: "arrow.up.forward.square",
        accessibilityDescription: "Open Settings"
      )
      item.attributedTitle = noInstancesAttributedTitle()
      menu.addItem(item)
    } else {
      let (dotColor, statusText) = resolveStatusColor(
        connectionStatuses: connectionStatuses,
        blockingStatuses: blockingStatuses,
        servers: servers
      )
      let statusItem = NSMenuItem()
      statusItem.attributedTitle = MenuItemFactory.statusLine(
        dotColor: dotColor,
        text: statusText
      )
      statusItem.isEnabled = false
      menu.addItem(statusItem)

      let totalQueries = querySummaries.values.reduce(0) { $0 + $1.totalQueries }
      let totalBlocked = querySummaries.values.reduce(0) { $0 + $1.totalBlocked }
      let statsItem = NSMenuItem()
      statsItem.attributedTitle = MenuItemFactory.statsLine(
        totalQueries: totalQueries,
        totalBlocked: totalBlocked
      )
      statsItem.isEnabled = false
      menu.addItem(statsItem)
    }
  }

  private func resolveStatusColor(
    connectionStatuses: [UUID: ConnectionStatus],
    blockingStatuses: [UUID: BlockingStatus],
    servers: [ServerConfig]
  ) -> (dotColor: NSColor, statusText: String) {
    if timerManager.isDisabled {
      return (.systemRed, "Blocking Disabled")
    }
    let connectedIDs = servers.compactMap { config in
      connectionStatuses[config.id] == .connected ? config.id : nil
    }
    if connectedIDs.isEmpty {
      return (.systemRed, "Blocking Disabled")
    }
    let blockingConnectedIDs = connectedIDs.filter { id in
      if case .enabled = blockingStatuses[id] { return true }
      return false
    }
    if blockingConnectedIDs.count == connectedIDs.count {
      return (.systemGreen, "Blocking Active")
    } else if !blockingConnectedIDs.isEmpty {
      return (.systemYellow, "Blocking Partially Active")
    } else {
      return (.systemRed, "Blocking Disabled")
    }
  }

  private func addInstancesSection(
    to menu: NSMenu,
    connectionStatuses: [UUID: ConnectionStatus],
    blockingStatuses: [UUID: BlockingStatus],
    querySummaries: [UUID: QuerySummary],
    servers: [ServerConfig]
  ) {
    guard !servers.isEmpty else { return }

    let connectedCount = connectionStatuses.values.filter { $0 == .connected }.count
    let showStats = connectedCount >= 2

    let groupItem = NSMenuItem()
    groupItem.attributedTitle = MenuItemFactory.instancesGroupLabel()
    groupItem.isEnabled = false
    menu.addItem(groupItem)

    for config in servers {
      let connected = connectionStatuses[config.id] == .connected
      let blocking = .enabled == blockingStatuses[config.id]
      let dotColor: NSColor = (connected && blocking) ? .systemGreen : .systemRed

      let item = NSMenuItem()
      if showStats, let summary = querySummaries[config.id] {
        item.attributedTitle = MenuItemFactory.instanceLineWithStats(
          dotColor: dotColor,
          icon: config.icon,
          label: config.label ?? config.url,
          totalQueries: summary.totalQueries,
          totalBlocked: summary.totalBlocked
        )
      } else {
        item.attributedTitle = MenuItemFactory.instanceLine(
          dotColor: dotColor,
          icon: config.icon,
          label: config.label ?? config.url
        )
      }
      item.isEnabled = false
      menu.addItem(item)
    }
  }

  private func addBlockingControls(to menu: NSMenu, isConnected: Bool) {
    if timerManager.isDisabled {
      let item = NSMenuItem(
        title: "Re-Enable Blocking", action: #selector(reEnableBlocking), keyEquivalent: ""
      )
      item.target = self
      item.isEnabled = isConnected && !serverManager.servers.isEmpty
      menu.addItem(item)
    } else {
      let submenu = NSMenu()

      submenu.addItem(withTitle: "Indefinitely", action: #selector(disableIndefinitely), keyEquivalent: "")
      submenu.addItem(withTitle: "10 seconds", action: #selector(disable10s), keyEquivalent: "")
      submenu.addItem(withTitle: "30 seconds", action: #selector(disable30s), keyEquivalent: "")
      submenu.addItem(withTitle: "5 minutes", action: #selector(disable5m), keyEquivalent: "")
      submenu.addItem(.separator())
      submenu.addItem(withTitle: "Custom...", action: #selector(disableCustom), keyEquivalent: "")

      for item in submenu.items {
        item.target = self
        item.isEnabled = isConnected
      }

      let item = NSMenuItem(title: "Disable Blocking", action: nil, keyEquivalent: "")
      item.submenu = submenu
      item.isEnabled = isConnected && !serverManager.servers.isEmpty
      menu.addItem(item)
    }
  }

  private func addRecentlyBlockedSection(
    to menu: NSMenu,
    recentBlocked: [BlockedDomain],
    isConnected: Bool
  ) {
    if recentBlocked.isEmpty {
      let item = NSMenuItem(title: "Recently Blocked", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
      return
    }

    let submenu = NSMenu()
    for entry in recentBlocked {
      let durationSubmenu = buildDurationSubmenu(for: entry.domain)
      let domainItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
      domainItem.attributedTitle = attributedTitle(for: entry)
      domainItem.submenu = durationSubmenu

      if showAllClients, entry.fromClientIp == userIP {
        domainItem.image = .init(systemSymbolName: "person.circle", accessibilityDescription: "")
      }

      submenu.addItem(domainItem)
    }

    let item = NSMenuItem(title: "Recently Blocked", action: nil, keyEquivalent: "")
    item.submenu = submenu
    item.isEnabled = isConnected
    item.setAccessibilityLabel("Recently blocked domains")
    menu.addItem(item)
  }

  /// Builds a two-line attributed title: icon + "No instances configured" / "Configure in Settings…" below.
  private func noInstancesAttributedTitle() -> NSAttributedString {
    let result = NSMutableAttributedString()

    let titleAttr: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
      .foregroundColor: NSColor.labelColor
    ]
    result.append(NSAttributedString(string: "No instances configured", attributes: titleAttr))

    result.append(NSAttributedString(string: "\n"))

    let subtitleAttr: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
      .foregroundColor: NSColor.secondaryLabelColor
    ]
    result.append(NSAttributedString(string: "Configure in Settings…", attributes: subtitleAttr))

    return result
  }

  /// Builds a two-line attributed title: domain name + relative timestamp and hit count below.
  private func attributedTitle(for entry: BlockedDomain) -> NSAttributedString {
    let result = NSMutableAttributedString()

    let domainAttr: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
      .foregroundColor: NSColor.labelColor
    ]
    result.append(NSAttributedString(string: entry.domain, attributes: domainAttr))

    let timestamp = MenuItemFactory.relativeTimestamp(since: entry.timestamp)
    let hitSuffix = entry.count == 1 ? "1 hit" : "\(entry.count) hits"
    let timeAttr: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
      .foregroundColor: NSColor.secondaryLabelColor
    ]

    let subtitle = NSAttributedString(string: timestamp + " · " + hitSuffix, attributes: timeAttr)

    result.append(NSAttributedString(string: "\n"))
    result.append(subtitle)

    return result
  }

  private func buildDurationSubmenu(for domain: String) -> NSMenu {
    let submenu = NSMenu()

    addDurationItem(to: submenu, domain: domain, duration: 10, title: "10 seconds")
    addDurationItem(to: submenu, domain: domain, duration: 30, title: "30 seconds")
    addDurationItem(to: submenu, domain: domain, duration: 300, title: "5 minutes")

    submenu.addItem(.separator())

    let allowlistItem = NSMenuItem(
      title: "Add to allowlist",
      action: #selector(addToAllowlistAction),
      keyEquivalent: ""
    )
    allowlistItem.target = self
    allowlistItem.representedObject = domain
    submenu.addItem(allowlistItem)

    let customItem = NSMenuItem(title: "Custom...", action: #selector(disableURLWithCustomTime), keyEquivalent: "")
    customItem.target = self
    customItem.representedObject = domain
    submenu.addItem(customItem)

    return submenu
  }

  private func addDurationItem(to menu: NSMenu, domain: String, duration: TimeInterval, title: String) {
    let item = NSMenuItem(title: title, action: #selector(disableURLDurationAction), keyEquivalent: "")
    item.target = self
    item.representedObject = ["domain": domain, "duration": duration] as NSDictionary
    menu.addItem(item)
  }

  private func addBrowserTabSection(
    to menu: NSMenu,
    browserStatus: ResolvedBrowserTab,
    browserIcon: NSImage? = nil
  ) {
    switch browserStatus {
    case .disabled:
      return

    case .noBrowser:
      let item = NSMenuItem(title: "No browser detected", action: nil, keyEquivalent: "")
      item.isEnabled = false
      item.image = browserIcon
      menu.addItem(item)

    case .permissionNeeded(let browser):
      let item = NSMenuItem(
        title: "\(browser.appName) Detected. Enable Permission",
        action: #selector(enableBrowserPermissionAction),
        keyEquivalent: ""
      )
      item.target = self
      item.isEnabled = true
      item.image = browserIcon
      item.representedObject = browser
      menu.addItem(item)

    case .noURL:
      let item = NSMenuItem(title: "Could not get tab URL", action: nil, keyEquivalent: "")
      item.isEnabled = false
      item.image = browserIcon
      menu.addItem(item)

    case .url(let browser, let domain):
      let item = NSMenuItem(title: "Unblock \(domain)", action: nil, keyEquivalent: "")
      item.target = self
      item.isEnabled = true
      item.image = browserIcon
      item.submenu = buildDurationSubmenu(for: domain)
      menu.addItem(item)
    }
  }

  @objc private func enableBrowserPermissionAction(_ sender: NSMenuItem) {
    onEnableBrowserPermission?()
  }

  private func addSettingsAndQuit(to menu: NSMenu) {
    menu.addItem(.separator())

    let settingsItem = NSMenuItem(
      title: "Settings...", action: #selector(openSettings), keyEquivalent: ","
    )
    settingsItem.target = self
    menu.addItem(settingsItem)

    let checkForUpdatesItem = NSMenuItem(
      title: "Check for Updates…",
      action: #selector(checkForUpdates),
      keyEquivalent: ""
    )
    checkForUpdatesItem.target = self
    menu.addItem(checkForUpdatesItem)

    let quitItem = NSMenuItem(
      title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
    )
    menu.addItem(quitItem)
  }

  private func formattedRemaining(_ totalSeconds: TimeInterval) -> String {
    let seconds = Int(max(0, totalSeconds))
    if seconds >= 60 {
      return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    return "\(seconds)s"
  }

  @objc private func disableIndefinitely() { performBlocking(enabled: false, duration: nil) }
  @objc private func disable10s() { performBlocking(enabled: false, duration: 10) }
  @objc private func disable30s() { performBlocking(enabled: false, duration: 30) }
  @objc private func disable5m() { performBlocking(enabled: false, duration: 300) }

  @objc private func disableCustom() {
    let seconds = promptDuration(
      title: "Custom Disable Time",
      message: "Choose how long to disable blocking.",
      button: "Disable"
    )
    guard let seconds else { return }
    performBlocking(enabled: false, duration: seconds)
  }

  @objc private func reEnableBlocking() { performBlocking(enabled: true, duration: nil) }

  @objc private func disableURLDurationAction(_ sender: NSMenuItem) {
    guard let dict = sender.representedObject as? NSDictionary,
      let domain = dict["domain"] as? String,
      let duration = dict["duration"] as? TimeInterval
    else { return }
    onDisableURL?(domain, duration)
  }

  @objc private func disableURLWithCustomTime(_ sender: NSMenuItem) {
    guard let domain = sender.representedObject as? String else { return }
    let seconds = promptDuration(
      title: "Custom Unblock Duration",
      message: "Choose how long to unblock \"\(domain)\".",
      button: "Unblock"
    )
    guard let seconds else { return }
    onDisableURL?(domain, seconds)
  }

  /// Shows an alert with a DatePicker (hour:minute:second) and returns the duration in seconds, or nil if cancelled.
  private func promptDuration(title: String, message: String, button: String) -> TimeInterval? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: "Cancel")

    let datePicker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
    datePicker.datePickerStyle = .textFieldAndStepper
    datePicker.datePickerElements = .hourMinuteSecond
    datePicker.locale = Locale(identifier: "en_GB")  // 24-hour format
    let calendar = Calendar.current
    let defaultDate = calendar.date(bySettingHour: 0, minute: 5, second: 0, of: Date()) ?? Date()
    datePicker.dateValue = defaultDate
    datePicker.minDate = calendar.startOfDay(for: Date())
    alert.accessoryView = datePicker

    // Force synchronous layout before entering the modal run loop.
    // NSDatePicker lazily initializes its internal date formatter on first layout,
    // dispatching that work at Default QoS. Without this, the picker can appear
    // blank or trigger a QoS inversion warning during runModal() on the main thread.
    datePicker.layoutSubtreeIfNeeded()

    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return nil }

    let components = calendar.dateComponents([.hour, .minute, .second], from: datePicker.dateValue)
    let hrs = (components.hour ?? 0) * 3600
    let mins = (components.minute ?? 0) * 60
    let secs = components.second ?? 0
    let seconds = TimeInterval(hrs + mins + secs)
    return seconds > 0 ? seconds : nil
  }

  @objc private func addToAllowlistAction(_ sender: NSMenuItem) {
    guard let domain = sender.representedObject as? String else { return }
    onAddToAllowlist?(domain)
  }

  @objc private func openSettings() { SettingsWindowController.shared.showWindow() }

  @objc private func checkForUpdates() {
    updater.checkForUpdates()
  }

  private func performBlocking(enabled: Bool, duration: TimeInterval?) {
    guard let server = serverManager.servers.first else { return }
    Task {
      do {
        try await serverManager.setBlocking(for: server.id, enabled: enabled, duration: duration)
        if enabled {
          timerManager.cancelDisable()
        } else {
          timerManager.startDisable(duration: duration)
        }
      } catch {
        logger.error("Blocking action failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}
// swiftlint:enable type_body_length
