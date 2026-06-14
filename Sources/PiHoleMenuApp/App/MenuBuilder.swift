import AppKit
import OSLog

@MainActor
final class MenuBuilder: NSObject {
  private let serverManager: PiholeServerManager
  private let timerManager: TimerManager
  private let tempUnblockManager: TempUnblockManager
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "menu-builder")

  var onDisableURL: ((String, TimeInterval) -> Void)?
  var onReBlockDomain: ((String) -> Void)?

  init(
    serverManager: PiholeServerManager,
    timerManager: TimerManager,
    tempUnblockManager: TempUnblockManager = .shared
  ) {
    self.serverManager = serverManager
    self.timerManager = timerManager
    self.tempUnblockManager = tempUnblockManager
  }

  func buildMenu(
    recentBlocked: [String],
    error: String?,
    isConnected: Bool,
    activeRecords: [TempUnblockRecord],
    maxUnblocks: Int
  ) -> NSMenu {
    let menu = NSMenu()
    addStatusSection(to: menu, error: error, isConnected: isConnected, records: activeRecords)
    menu.addItem(.separator())
    addBlockingControls(to: menu, isConnected: isConnected)
    menu.addItem(.separator())
    addDisableURLSection(
      to: menu, recentBlocked: recentBlocked, activeRecords: activeRecords,
      maxUnblocks: maxUnblocks, isConnected: isConnected
    )
    menu.addItem(.separator())
    addActiveUnblockSection(to: menu, activeRecords: activeRecords, isConnected: isConnected)
    menu.addItem(.separator())
    addSettingsAndQuit(to: menu)
    return menu
  }

  func updateCountdowns(in menu: NSMenu) {
    let now = Date()
    for item in menu.items {
      guard let identifier = item.identifier?.rawValue, identifier.hasPrefix("unblock-countdown"),
        let uuid = identifier.split(separator: ":").last.map(String.init)
      else { continue }

      guard let record = tempUnblockManager.activeRecords.first(where: { $0.uuid == uuid })
      else { continue }

      let elapsed = now.timeIntervalSince(record.startDateUTC)
      let remaining = max(0, record.durationSeconds - elapsed)
      item.title = "\(record.domain)  (\(formattedRemaining(remaining)))"

      if let submenu = item.submenu, submenu.items.count >= 2 {
        let infoItem = submenu.items[0]
        infoItem.title = "\(formattedRemaining(remaining)) remaining"
      }
    }
  }

  // MARK: - Status Section

  private func addStatusSection(to menu: NSMenu, error: String?, isConnected: Bool, records: [TempUnblockRecord]) {
    let statusTitle = buildStatusText(error: error, isConnected: isConnected)
    let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
    statusItem.isEnabled = false
    menu.addItem(statusItem)

    if serverManager.servers.count > 1 {
      let countItem = NSMenuItem(
        title: "\(serverManager.servers.count) instances configured", action: nil, keyEquivalent: ""
      )
      countItem.isEnabled = false
      menu.addItem(countItem)
    }
  }

  private func buildStatusText(error: String?, isConnected: Bool) -> String {
    if let error {
      return "⚠ \(error)"
    }
    if !isConnected {
      return "Disconnected"
    }
    if serverManager.servers.isEmpty {
      return "No instances configured"
    }
    if timerManager.isDisabled {
      return "Blocking Disabled"
    }
    return "Blocking Active"
  }

  // MARK: - Blocking Controls

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

  // MARK: - Disable Specific URL

  private func addDisableURLSection(
    to menu: NSMenu, recentBlocked: [String], activeRecords: [TempUnblockRecord], maxUnblocks: Int,
    isConnected: Bool
  ) {
    let atCap = activeRecords.count >= maxUnblocks
    let deduped = Array(NSOrderedSet(array: recentBlocked)).compactMap { $0 as? String }

    if atCap || deduped.isEmpty {
      let title = atCap ? "Recently Blocked (limit reached)" : "Recently Blocked"
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
      return
    }

    let submenu = NSMenu()
    for domain in deduped {
      let durationSubmenu = buildDurationSubmenu(for: domain)
      let domainItem = NSMenuItem(title: domain, action: nil, keyEquivalent: "")
      domainItem.submenu = durationSubmenu
      submenu.addItem(domainItem)
    }

    let item = NSMenuItem(title: "Recently Blocked", action: nil, keyEquivalent: "")
    item.submenu = submenu
    item.isEnabled = isConnected
    menu.addItem(item)
  }

  private func buildDurationSubmenu(for domain: String) -> NSMenu {
    let submenu = NSMenu()

    addDurationItem(to: submenu, domain: domain, duration: 30, title: "30 seconds")
    addDurationItem(to: submenu, domain: domain, duration: 300, title: "5 minutes")
    addDurationItem(to: submenu, domain: domain, duration: 900, title: "15 minutes")
    submenu.addItem(.separator())

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

  // MARK: - Active Unblock Section

  private func addActiveUnblockSection(to menu: NSMenu, activeRecords: [TempUnblockRecord], isConnected: Bool) {
    let now = Date()

    for record in activeRecords {
      let elapsed = now.timeIntervalSince(record.startDateUTC)
      let remaining = max(0, record.durationSeconds - elapsed)
      let title = "\(record.domain)  (\(formattedRemaining(remaining)))"

      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.identifier = NSUserInterfaceItemIdentifier("unblock-countdown:\(record.uuid)")

      let submenu = NSMenu()
      let infoItem = NSMenuItem(title: "\(formattedRemaining(remaining)) remaining", action: nil, keyEquivalent: "")
      infoItem.isEnabled = false
      submenu.addItem(infoItem)

      let reblockItem = NSMenuItem(title: "Re-block now", action: #selector(reblockDomain), keyEquivalent: "")
      reblockItem.target = self
      reblockItem.representedObject = record.uuid
      reblockItem.isEnabled = isConnected
      submenu.addItem(reblockItem)

      item.submenu = submenu
      menu.addItem(item)
    }
  }

  // MARK: - Settings & Quit

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

  // MARK: - Helpers

  private func formattedRemaining(_ totalSeconds: TimeInterval) -> String {
    let seconds = Int(max(0, totalSeconds))
    if seconds >= 60 {
      return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    return "\(seconds)s"
  }

  // MARK: - Actions: Blocking

  @objc private func disableIndefinitely() {
    performBlocking(enabled: false, duration: nil)
  }

  @objc private func disable10s() {
    performBlocking(enabled: false, duration: 10)
  }

  @objc private func disable30s() {
    performBlocking(enabled: false, duration: 30)
  }

  @objc private func disable5m() {
    performBlocking(enabled: false, duration: 300)
  }

  @objc private func disableCustom() {
    let alert = NSAlert()
    alert.messageText = "Custom Disable Time"
    alert.informativeText = "Enter the number of seconds to disable blocking."
    alert.addButton(withTitle: "Disable")
    alert.addButton(withTitle: "Cancel")

    let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    textField.placeholderString = "e.g. 120"
    alert.accessoryView = textField

    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
      let text = textField.stringValue.trimmingCharacters(in: .whitespaces)
      if let seconds = TimeInterval(text), seconds > 0 {
        performBlocking(enabled: false, duration: seconds)
      }
    }
  }

  @objc private func reEnableBlocking() {
    performBlocking(enabled: true, duration: nil)
  }

  // MARK: - Actions: Disable Specific URL

  @objc private func disableURLDurationAction(_ sender: NSMenuItem) {
    guard let dict = sender.representedObject as? NSDictionary,
      let domain = dict["domain"] as? String,
      let duration = dict["duration"] as? TimeInterval
    else { return }
    onDisableURL?(domain, duration)
  }

  @objc private func disableURLWithCustomTime(_ sender: NSMenuItem) {
    guard let domain = sender.representedObject as? String else { return }

    let alert = NSAlert()
    alert.messageText = "Custom Unblock Duration"
    alert.informativeText = "Enter the number of seconds to unblock \"\(domain)\"."
    alert.addButton(withTitle: "Unblock")
    alert.addButton(withTitle: "Cancel")

    let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    textField.placeholderString = "e.g. 120"
    alert.accessoryView = textField

    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
      let text = textField.stringValue.trimmingCharacters(in: .whitespaces)
      if let seconds = TimeInterval(text), seconds > 0 {
        onDisableURL?(domain, seconds)
      }
    }
  }

  // MARK: - Actions: Re-block

  @objc private func reblockDomain(_ sender: NSMenuItem) {
    guard let uuid = sender.representedObject as? String else { return }
    onReBlockDomain?(uuid)
  }

  // MARK: - Actions: Settings

  @objc private func openSettings() {
    SettingsWindowController.shared.showWindow()
  }

  // MARK: - Blocking Execution

  private func performBlocking(enabled: Bool, duration: TimeInterval?) {
    guard let server = serverManager.servers.first, server.version != nil else { return }
    Task {
      do {
        try await serverManager.setBlocking(for: server, enabled: enabled, duration: duration)
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
