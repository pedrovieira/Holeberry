import AppKit

class MenuBuilder {
    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Status row (disabled, informational)
        let statusItem = NSMenuItem(title: "● Pi-hole Status", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // Placeholder items
        let disableItem = NSMenuItem(title: "Disable Blocking", action: nil, keyEquivalent: "")
        disableItem.isEnabled = false
        menu.addItem(disableItem)

        let recentBlockedItem = NSMenuItem(title: "Recent Blocked", action: nil, keyEquivalent: "")
        recentBlockedItem.isEnabled = false
        menu.addItem(recentBlockedItem)

        menu.addItem(NSMenuItem.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    @objc private func showSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
