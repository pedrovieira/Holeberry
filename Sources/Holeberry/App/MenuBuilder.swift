import AppKit
import OSLog

// swiftlint:disable file_length

@MainActor
final class MenuBuilder: NSObject {
  private let serverManager: PiholeServerManager
  private let timerManager: TimerManager
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "menu-builder")

  var onDisableURL: ((String, TimeInterval) -> Void)?
  var onAddToAllowlist: ((String) -> Void)?


  init(
    serverManager: PiholeServerManager,
    timerManager: TimerManager
  ) {
    self.serverManager = serverManager
    self.timerManager = timerManager
  }

  // swiftlint:disable:next function_parameter_count
  func buildMenu(
    recentBlocked: [BlockedDomain],
    error: String?,
    isConnected: Bool,
    combinedStatus: CombinedStatus,
    connectionStatuses: [UUID: ConnectionStatus],
    blockingStatuses: [UUID: BlockingStatus],
    servers: [ServerConfig],
    browserTabStatus: BrowserUrlFetcher.Status = .disabled,
    browserIcon: NSImage? = nil
  ) -> NSMenu {
    let menu = NSMenu()
    addStatusSection(
      to: menu,
      error: error,
      isConnected: isConnected,
      combinedStatus: combinedStatus,
      connectionStatuses: connectionStatuses,
      blockingStatuses: blockingStatuses,
      servers: servers
    )
    menu.addItem(.separator())
    addInstancesSection(
      to: menu,
      connectionStatuses: connectionStatuses,
      blockingStatuses: blockingStatuses,
      servers: servers
    )
    menu.addItem(.separator())
    addBlockingControls(to: menu, isConnected: isConnected)
    menu.addItem(.separator())
    addBrowserTabSection(to: menu, browserStatus: browserTabStatus, browserIcon: browserIcon)
    menu.addItem(.separator())
    addDisableURLSection(
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
    combinedStatus: CombinedStatus,
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
      let item = NSMenuItem(title: "No instances configured", action: nil, keyEquivalent: "")
      item.isEnabled = false
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

      let statsItem = NSMenuItem()
      statsItem.attributedTitle = MenuItemFactory.statsLine(
        totalQueries: combinedStatus.totalQueries,
        totalBlocked: combinedStatus.totalBlocked
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
    servers: [ServerConfig]
  ) {
    guard !servers.isEmpty else { return }

    let groupItem = NSMenuItem()
    groupItem.attributedTitle = MenuItemFactory.instancesGroupLabel()
    groupItem.isEnabled = false
    menu.addItem(groupItem)

    for config in servers {
      let connected = connectionStatuses[config.id] == .connected
      let blocking = if case .enabled = blockingStatuses[config.id] { true } else { false }
      let dotColor: NSColor = (connected && blocking) ? .systemGreen : .systemRed

      let item = NSMenuItem()
      item.attributedTitle = MenuItemFactory.instanceLine(
        dotColor: dotColor,
        icon: config.icon,
        label: config.label ?? config.url
      )
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

  private func addDisableURLSection(
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
      submenu.addItem(domainItem)
    }

    let item = NSMenuItem(title: "Recently Blocked", action: nil, keyEquivalent: "")
    item.submenu = submenu
    item.isEnabled = isConnected
    item.setAccessibilityLabel("Recently blocked domains")
    menu.addItem(item)
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
    result.append(NSAttributedString(string: "\n" + timestamp + " · " + hitSuffix, attributes: timeAttr))

    return result
  }

  private func buildDurationSubmenu(for domain: String) -> NSMenu {
    let submenu = NSMenu()

    addDurationItem(to: submenu, domain: domain, duration: 30, title: "30 seconds")
    addDurationItem(to: submenu, domain: domain, duration: 300, title: "5 minutes")
    addDurationItem(to: submenu, domain: domain, duration: 900, title: "15 minutes")
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
    browserStatus: BrowserUrlFetcher.Status,
    browserIcon: NSImage? = nil
  ) {
    let title: String
    let enabled: Bool

    switch browserStatus {
    case .disabled:
      return  // no item shown
    case .noBrowser:
      title = "No browser focused"
      enabled = false

    case .permissionDenied:
      title = "Permission needed"
      enabled = false
    case .noURL:
      title = "Could not get URL"
      enabled = false
    case .url(let domain):
      title = "Unblock \(domain)"
      enabled = true

      let item = NSMenuItem(
        title: title,
        action: nil,
        keyEquivalent: ""
      )
      item.target = self
      item.isEnabled = enabled
      item.image = browserIcon
      item.submenu = buildDurationSubmenu(for: domain)
      menu.addItem(item)
      return
    }

    let item = NSMenuItem(
      title: title,
      action: nil,
      keyEquivalent: ""
    )
    item.target = self
    item.isEnabled = enabled
    item.image = browserIcon
    menu.addItem(item)
  }

  private func addSettingsAndQuit(to menu: NSMenu) {
    let settingsItem = NSMenuItem(
      title: "Settings...", action: #selector(openSettings), keyEquivalent: ","
    )
    settingsItem.target = self
    menu.addItem(settingsItem)

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
