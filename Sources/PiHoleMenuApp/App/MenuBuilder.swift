import AppKit
import OSLog

@MainActor
final class MenuBuilder: NSObject {
  private let serverManager: PiholeServerManager
  private let timerManager: TimerManager
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "menu-builder")

  init(serverManager: PiholeServerManager, timerManager: TimerManager) {
    self.serverManager = serverManager
    self.timerManager = timerManager
  }

  func buildMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(statusItem)
    menu.addItem(.separator())
    addBlockingControls(to: menu)
    menu.addItem(.separator())
    addRecentBlocked(to: menu)
    menu.addItem(.separator())
    addSettingsAndQuit(to: menu)
    return menu
  }

  private var statusItem: NSMenuItem {
    let item: NSMenuItem
    if serverManager.servers.isEmpty {
      item = NSMenuItem(title: "No instances configured", action: nil, keyEquivalent: "")
    } else if timerManager.isDisabled {
      item = NSMenuItem(title: "Blocking Disabled", action: nil, keyEquivalent: "")
    } else {
      item = NSMenuItem(title: "Blocking Active", action: nil, keyEquivalent: "")
    }
    item.isEnabled = false
    return item
  }

  private func addBlockingControls(to menu: NSMenu) {
    if timerManager.isDisabled {
      let item = NSMenuItem(
        title: "Re-Enable Blocking", action: #selector(reEnableBlocking), keyEquivalent: ""
      )
      item.target = self
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
      }

      let item = NSMenuItem(title: "Disable Blocking", action: nil, keyEquivalent: "")
      item.submenu = submenu
      menu.addItem(item)
    }
  }

  private func addRecentBlocked(to menu: NSMenu) {
    let item = NSMenuItem(title: "Recent Blocked", action: nil, keyEquivalent: "")
    item.isEnabled = false
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

  // MARK: - Actions

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

  @objc private func openSettings() {
    SettingsWindowController.shared.showWindow()
  }

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
