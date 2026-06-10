import AppKit

class MenuBarController {
    private let statusItem: NSStatusItem
    private let menuBuilder = MenuBuilder()

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusItem()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "shield", accessibilityDescription: "Pi-hole Menu")
        button.action = #selector(showMenu)
        button.target = self
    }

    @objc private func showMenu() {
        statusItem.menu = menuBuilder.buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}
