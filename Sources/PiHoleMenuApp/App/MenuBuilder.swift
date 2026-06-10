import AppKit
import SwiftUI

class MenuBuilder: NSObject {
  private weak var settingsWindow: NSWindow?

  func buildMenu() -> NSMenu {
    let menu = NSMenu()

    let statusItem = NSMenuItem(title: "● Pi-hole Status", action: nil, keyEquivalent: "")
    statusItem.isEnabled = false
    menu.addItem(statusItem)

    menu.addItem(NSMenuItem.separator())

    let disableItem = NSMenuItem(title: "Disable Blocking", action: nil, keyEquivalent: "")
    disableItem.isEnabled = false
    menu.addItem(disableItem)

    let recentBlockedItem = NSMenuItem(title: "Recent Blocked", action: nil, keyEquivalent: "")
    recentBlockedItem.isEnabled = false
    menu.addItem(recentBlockedItem)

    menu.addItem(NSMenuItem.separator())

    let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
    settingsItem.target = self
    menu.addItem(settingsItem)

    let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.addItem(quitItem)

    return menu
  }

  @objc private func showSettings() {
    if let existing = settingsWindow {
      existing.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.contentView = NSHostingView(rootView: SettingsView())
    window.title = "Settings"
    window.center()
    window.setFrameAutosaveName("Settings")
    window.delegate = self
    settingsWindow = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

extension MenuBuilder: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    settingsWindow = nil
  }
}
