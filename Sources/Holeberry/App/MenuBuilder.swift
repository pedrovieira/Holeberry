import AppKit

// swiftlint:disable file_length

/// Stateless menu-construction helper.
///
/// Receives all data and actions as parameters; returns a fully-built
/// `MainStatusBarMenu` whose items target the shared `MenuActionTarget`.
/// No dependencies on `PiholeServerManager`, `TimerManager`, or `SPUUpdater`.
@MainActor
struct MenuBuilder {
  // swiftlint:disable:next function_parameter_count
  func buildMenu(
    actions: MenuActions,
    isTimerDisabled: Bool,
    recentBlocked: [BlockedDomain],
    userIP: String?,
    showAllClients: Bool,
    error: String?,
    isConnected: Bool,
    connectionStatuses: [UUID: ConnectionStatus],
    blockingStatuses: [UUID: BlockingStatus],
    querySummaries: [UUID: QuerySummary],
    servers: [ServerConfig],
    browserTabStatus: ResolvedBrowserTab,
    browserIcon: NSImage?
  ) -> MainStatusBarMenu {
    let target = MenuActionTarget(actions: actions)
    let menu = MainStatusBarMenu(actionTarget: target)

    addStatusSection(
      to: menu,
      error: error,
      isConnected: isConnected,
      isTimerDisabled: isTimerDisabled,
      servers: servers,
      querySummaries: querySummaries,
      connectionStatuses: connectionStatuses,
      blockingStatuses: blockingStatuses,
      target: target
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

    addBlockingControls(
      to: menu,
      isTimerDisabled: isTimerDisabled,
      hasServers: !servers.isEmpty,
      isConnected: isConnected,
      target: target
    )

    if browserTabStatus != .disabled {
      menu.addItem(.separator())
      addBrowserTabSection(to: menu, browserStatus: browserTabStatus, browserIcon: browserIcon, target: target)
    }

    menu.addItem(.separator())
    addRecentlyBlockedSection(
      to: menu,
      recentBlocked: recentBlocked,
      userIP: userIP,
      showAllClients: showAllClients,
      isConnected: isConnected,
      target: target
    )
    menu.addItem(.separator())
    addSettingsAndQuit(to: menu, target: target)

    return menu
  }

  // MARK: - Status section

  // swiftlint:disable:next function_parameter_count
  private func addStatusSection(
    to menu: NSMenu,
    error: String?,
    isConnected: Bool,
    isTimerDisabled: Bool,
    servers: [ServerConfig],
    querySummaries: [UUID: QuerySummary],
    connectionStatuses: [UUID: ConnectionStatus],
    blockingStatuses: [UUID: BlockingStatus],
    target: MenuActionTarget
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
      let item = NSMenuItem(
        title: "",
        action: #selector(MenuActionTarget.openAppSettings),
        keyEquivalent: ""
      )
      item.target = target
      item.image = NSImage(
        systemSymbolName: "arrow.up.forward.square",
        accessibilityDescription: "Open Settings"
      )
      item.attributedTitle = noInstancesAttributedTitle()
      menu.addItem(item)
    } else {
      let (dotColor, statusText) = resolveStatusColor(
        isTimerDisabled: isTimerDisabled,
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
    isTimerDisabled: Bool,
    connectionStatuses: [UUID: ConnectionStatus],
    blockingStatuses: [UUID: BlockingStatus],
    servers: [ServerConfig]
  ) -> (dotColor: NSColor, statusText: String) {
    if isTimerDisabled {
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

  // MARK: - Instances section

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

  // MARK: - Blocking controls

  private func addBlockingControls(
    to menu: NSMenu,
    isTimerDisabled: Bool,
    hasServers: Bool,
    isConnected: Bool,
    target: MenuActionTarget
  ) {
    if isTimerDisabled {
      let item = NSMenuItem(
        title: "Re-Enable Blocking",
        action: #selector(MenuActionTarget.reEnableBlocking),
        keyEquivalent: ""
      )
      item.target = target
      item.isEnabled = isConnected && hasServers
      menu.addItem(item)
    } else {
      let submenu = NSMenu()

      addDisableDurationItem(to: submenu, duration: nil, title: "Indefinitely", target: target)
      addDisableDurationItem(to: submenu, duration: 10, title: "10 seconds", target: target)
      addDisableDurationItem(to: submenu, duration: 30, title: "30 seconds", target: target)
      addDisableDurationItem(to: submenu, duration: 300, title: "5 minutes", target: target)

      submenu.addItem(.separator())

      let customItem = NSMenuItem(
        title: "Custom...",
        action: #selector(MenuActionTarget.disableCustomDuration),
        keyEquivalent: ""
      )
      customItem.target = target
      submenu.addItem(customItem)

      for item in submenu.items {
        item.isEnabled = isConnected
      }

      let menuItem = NSMenuItem(title: "Disable Blocking", action: nil, keyEquivalent: "")
      menuItem.submenu = submenu
      menuItem.isEnabled = isConnected && hasServers
      menu.addItem(menuItem)
    }
  }

  private func addDisableDurationItem(
    to menu: NSMenu,
    duration: TimeInterval?,
    title: String,
    target: MenuActionTarget
  ) {
    let item = NSMenuItem(
      title: title,
      action: #selector(MenuActionTarget.toggleDisableBlocking),
      keyEquivalent: ""
    )
    item.target = target
    // nil representedObject = indefinitely (handled by toggleDisableBlocking)
    item.representedObject = duration as Any?
    menu.addItem(item)
  }

  // MARK: - Recently blocked section

  // swiftlint:disable:next function_parameter_count
  private func addRecentlyBlockedSection(
    to menu: NSMenu,
    recentBlocked: [BlockedDomain],
    userIP: String?,
    showAllClients: Bool,
    isConnected: Bool,
    target: MenuActionTarget
  ) {
    if recentBlocked.isEmpty {
      let item = NSMenuItem(title: "Recently Blocked", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
      return
    }

    // Capture `self` and `target` strongly — `self` (MenuBuilder) is used once
    // to build the closure that `RecentlyBlockedMenu` stores for its lifetime.
    let submenu = RecentlyBlockedMenu(
      blockedDomains: recentBlocked,
      userIP: userIP,
      showAllClients: showAllClients
    ) { [self, target] domain in
      self.buildDurationSubmenu(for: domain, target: target)
    }

    let item = NSMenuItem(title: "Recently Blocked...", action: nil, keyEquivalent: "")
    item.submenu = submenu
    item.isEnabled = isConnected
    item.setAccessibilityLabel("Recently blocked domains")
    menu.addItem(item)
  }

  // MARK: - Duration submenu (shared for browser tab + recently blocked)

  private func buildDurationSubmenu(for domain: String, target: MenuActionTarget) -> NSMenu {
    let submenu = NSMenu()

    addDurationItem(to: submenu, domain: domain, duration: 10, title: "10 seconds", target: target)
    addDurationItem(to: submenu, domain: domain, duration: 30, title: "30 seconds", target: target)
    addDurationItem(to: submenu, domain: domain, duration: 300, title: "5 minutes", target: target)

    submenu.addItem(.separator())

    let allowlistItem = NSMenuItem(
      title: "Add to allowlist",
      action: #selector(MenuActionTarget.addToAllowlistAction),
      keyEquivalent: ""
    )
    allowlistItem.target = target
    allowlistItem.representedObject = domain
    submenu.addItem(allowlistItem)

    let customItem = NSMenuItem(
      title: "Custom...",
      action: #selector(MenuActionTarget.disableURLWithCustomTime),
      keyEquivalent: ""
    )
    customItem.target = target
    customItem.representedObject = domain
    submenu.addItem(customItem)

    return submenu
  }

  private func addDurationItem(
    to menu: NSMenu,
    domain: String,
    duration: TimeInterval,
    title: String,
    target: MenuActionTarget
  ) {
    let item = NSMenuItem(
      title: title,
      action: #selector(MenuActionTarget.disableURLDurationAction),
      keyEquivalent: ""
    )
    item.target = target
    item.representedObject = ["domain": domain, "duration": duration] as NSDictionary
    menu.addItem(item)
  }

  // MARK: - Browser tab section

  private func addBrowserTabSection(
    to menu: NSMenu,
    browserStatus: ResolvedBrowserTab,
    browserIcon: NSImage?,
    target: MenuActionTarget
  ) {
    switch browserStatus {
    case .disabled:
      return

    case .noBrowser:
      let item = NSMenuItem(title: "No browser detected", action: nil, keyEquivalent: "")
      item.isEnabled = false
      item.image = browserIcon
      menu.addItem(item)

    case .permissionDenied(let browser):
      let item = NSMenuItem(
        title: "\(browser.appName) Permission Denied. Open Settings",
        action: #selector(MenuActionTarget.openAutomationSettingsAction),
        keyEquivalent: ""
      )
      item.target = target
      item.isEnabled = true
      item.image = browserIcon
      menu.addItem(item)

    case .permissionNeeded(let browser):
      let item = NSMenuItem(
        title: "\(browser.appName) Detected. Enable Permission",
        action: #selector(MenuActionTarget.enableBrowserPermissionAction),
        keyEquivalent: ""
      )
      item.target = target
      item.isEnabled = true
      item.image = browserIcon
      item.representedObject = browser
      menu.addItem(item)

    case .noURL:
      let item = NSMenuItem(title: "Could not get tab URL", action: nil, keyEquivalent: "")
      item.isEnabled = false
      item.image = browserIcon
      menu.addItem(item)

    case .url(_, let domain):
      let item = NSMenuItem(title: "Unblock \(domain)", action: nil, keyEquivalent: "")
      item.isEnabled = true
      item.image = browserIcon
      item.submenu = buildDurationSubmenu(for: domain, target: target)
      menu.addItem(item)
    }
  }

  // MARK: - Settings / Quit

  private func addSettingsAndQuit(to menu: NSMenu, target: MenuActionTarget) {
    menu.addItem(.separator())

    let settingsItem = NSMenuItem(
      title: "Settings…",
      action: #selector(MenuActionTarget.openAppSettings),
      keyEquivalent: ","
    )
    settingsItem.target = target
    settingsItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: "Settings")
    menu.addItem(settingsItem)

    let checkForUpdatesItem = NSMenuItem(
      title: "Check for Updates…",
      action: #selector(MenuActionTarget.checkForUpdates),
      keyEquivalent: ""
    )
    checkForUpdatesItem.target = target
    menu.addItem(checkForUpdatesItem)

    let quitItem = NSMenuItem(
      title: "Quit",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    menu.addItem(quitItem)
  }

  // MARK: - Helpers

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
}
