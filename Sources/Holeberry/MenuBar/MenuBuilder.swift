import AppKit
import HoleberryCore

// swiftlint:disable file_length type_body_length

/// Amber color (#ff9f0a) for the "instances disagree" state.
private let statusAmber = NSColor(calibratedRed: 1.0, green: 0.624, blue: 0.039, alpha: 1.0)

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
    recentBlockedProvider: @escaping () -> [BlockedDomain],
    userIP: String?,
    showAllClients: Bool,
    showPerInstanceStats: Bool,
    durations: [UnblockDurationEntry],
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
    let hasHealthyInstance = servers.contains { connectionStatuses[$0.id] == .connected }

    addStatusSection(
      to: menu,
      isConnected: isConnected,
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
      servers: servers,
      showPerInstanceStats: showPerInstanceStats
    )
    menu.addItem(.separator())

    addBlockingControls(
      to: menu,
      isTimerDisabled: isTimerDisabled,
      hasServers: !servers.isEmpty,
      hasHealthyInstance: hasHealthyInstance,
      isConnected: isConnected,
      durations: durations,
      target: target
    )

    if browserTabStatus != .disabled {
      menu.addItem(.separator())
      addBrowserTabSection(
        to: menu,
        browserStatus: browserTabStatus,
        browserIcon: browserIcon,
        durations: durations,
        hasHealthyInstance: hasHealthyInstance,
        target: target
      )
    }

    menu.addItem(.separator())
    addRecentlyBlockedSection(
      to: menu,
      recentBlockedProvider: recentBlockedProvider,
      userIP: userIP,
      showAllClients: showAllClients,
      durations: durations,
      isConnected: isConnected,
      hasHealthyInstance: hasHealthyInstance,
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
    isConnected: Bool,
    servers: [ServerConfig],
    querySummaries: [UUID: QuerySummary],
    connectionStatuses: [UUID: ConnectionStatus],
    blockingStatuses: [UUID: BlockingStatus],
    target: MenuActionTarget
  ) {
    if !isConnected {
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
    // 1. Any instance unreachable → red
    let allReachable = servers.allSatisfy { connectionStatuses[$0.id] == .connected }
    guard allReachable else {
      return (.systemRed, "Instance Unreachable")
    }

    // 2. Check blocking state among reachable servers
    let blockingCount = servers.filter { config in
      if case .enabled = blockingStatuses[config.id] { return true }
      return false
    }.count

    let allBlocking = blockingCount == servers.count
    let noneBlocking = blockingCount == 0

    if !allBlocking && !noneBlocking {
      // 3. Instances disagree → amber
      return (statusAmber, "Blocking Partially Active")
    } else if allBlocking {
      // 4. All blocking → green
      return (.systemGreen, "Blocking Active")
    } else {
      // 5. All confirmed off → gray
      return (.systemGray, "Blocking Disabled")
    }
  }

  // MARK: - Instances section

  // swiftlint:disable:next function_parameter_count
  private func addInstancesSection(
    to menu: NSMenu,
    connectionStatuses: [UUID: ConnectionStatus],
    blockingStatuses: [UUID: BlockingStatus],
    querySummaries: [UUID: QuerySummary],
    servers: [ServerConfig],
    showPerInstanceStats: Bool
  ) {
    guard !servers.isEmpty else { return }

    let connectedCount = connectionStatuses.values.filter { $0 == .connected }.count
    let showStats = connectedCount >= 2 && showPerInstanceStats

    let groupItem = NSMenuItem()
    groupItem.attributedTitle = MenuItemFactory.instancesGroupLabel()
    groupItem.isEnabled = false
    menu.addItem(groupItem)

    for config in servers {
      let connected = connectionStatuses[config.id] == .connected
      let blocking = .enabled == blockingStatuses[config.id]
      let dotColor: NSColor
      if !connected {
        dotColor = .systemRed
      } else if blocking {
        dotColor = .systemGreen
      } else {
        dotColor = .systemGray
      }

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

  // swiftlint:disable:next function_parameter_count
  private func addBlockingControls(
    to menu: NSMenu,
    isTimerDisabled: Bool,
    hasServers: Bool,
    hasHealthyInstance: Bool,
    isConnected: Bool,
    durations: [UnblockDurationEntry],
    target: MenuActionTarget
  ) {
    if isTimerDisabled {
      let item = NSMenuItem(
        title: "Re-Enable Blocking",
        action: #selector(MenuActionTarget.reEnableBlocking),
        keyEquivalent: ""
      )
      item.target = target
      item.isEnabled = isConnected && hasServers && hasHealthyInstance
      menu.addItem(item)
    } else {
      let submenu = NSMenu()

      for entry in durations {
        addDisableDurationItem(
          to: submenu,
          duration: entry.seconds,
          title: UnblockDurationFormatter.string(from: entry.seconds),
          target: target
        )
      }

      submenu.addItem(.separator())

      addDisableDurationItem(to: submenu, duration: nil, title: "Indefinitely", target: target)

      let customItem = NSMenuItem(
        title: "Custom...",
        action: #selector(MenuActionTarget.disableCustomDuration),
        keyEquivalent: ""
      )
      customItem.target = target
      submenu.addItem(customItem)

      for item in submenu.items {
        item.isEnabled = isConnected && hasHealthyInstance
      }

      let menuItem = NSMenuItem(title: "Disable Blocking", action: nil, keyEquivalent: "")
      menuItem.submenu = submenu
      menuItem.isEnabled = isConnected && hasServers && hasHealthyInstance
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
    recentBlockedProvider: @escaping () -> [BlockedDomain],
    userIP: String?,
    showAllClients: Bool,
    durations: [UnblockDurationEntry],
    isConnected: Bool,
    hasHealthyInstance: Bool,
    target: MenuActionTarget
  ) {
    // Capture `self` and `target` strongly — `self` (MenuBuilder) is used once
    // to build the closure that `RecentlyBlockedMenu` stores for its lifetime.
    let submenu = RecentlyBlockedMenu(
      fetchBlocked: recentBlockedProvider,
      userIP: userIP,
      showAllClients: showAllClients
    ) { [self, target, durations] domain in
      self.buildDurationSubmenu(for: domain, durations: durations, target: target)
    }

    let item = NSMenuItem(title: "Recently Blocked...", action: nil, keyEquivalent: "")
    item.submenu = submenu
    item.isEnabled = isConnected && hasHealthyInstance
    item.setAccessibilityLabel("Recently blocked domains")
    menu.addItem(item)
  }

  // MARK: - Duration submenu (shared for browser tab + recently blocked)

  private func buildDurationSubmenu(
    for domain: String,
    durations: [UnblockDurationEntry],
    target: MenuActionTarget
  ) -> NSMenu {
    let submenu = NSMenu()

    for entry in durations {
      addDurationItem(
        to: submenu,
        domain: domain,
        duration: entry.seconds,
        title: UnblockDurationFormatter.string(from: entry.seconds),
        target: target
      )
    }

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

  // swiftlint:disable:next function_parameter_count
  private func addBrowserTabSection(
    to menu: NSMenu,
    browserStatus: ResolvedBrowserTab,
    browserIcon: NSImage?,
    durations: [UnblockDurationEntry],
    hasHealthyInstance: Bool,
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
      let item = NSMenuItem(
        title: "Unblock \(menuLabelDomain(for: domain))",
        action: nil,
        keyEquivalent: ""
      )
      item.isEnabled = hasHealthyInstance
      item.image = browserIcon
      item.submenu = buildDurationSubmenu(for: domain, durations: durations, target: target)
      menu.addItem(item)
    }
  }

  /// Strips a leading "www." for display only. The domain used for unblocking
  /// keeps its original form.
  private func menuLabelDomain(for domain: String) -> String {
    guard domain.count > 4, domain.lowercased().hasPrefix("www.") else {
      return domain
    }
    return String(domain.dropFirst(4))
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
