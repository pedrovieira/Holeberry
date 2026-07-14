import AppKit
import Sparkle
import SwiftUI

final class SettingsWindowController: NSWindowController {
  static let shared = SettingsWindowController()

  private var updater: SPUUpdater?

  private init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 580, height: 420),
      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    super.init(window: window)
    setupWindow()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setUpdater(_ updater: SPUUpdater) {
    self.updater = updater
    setupWindow()
  }

  private func setupWindow() {
    window?.title = "Settings"
    window?.identifier = NSUserInterfaceItemIdentifier("Settings")
    window?.titlebarAppearsTransparent = false
    window?.titleVisibility = .visible
    window?.toolbarStyle = .unified
    window?.contentView = NSHostingView(rootView: SettingsView(serverManager: .shared, updater: updater))
    window?.setFrameAutosaveName("Settings")
    window?.collectionBehavior = .managed
    window?.delegate = self
  }

  func showWindow() {
    if window?.isVisible == true {
      window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    window?.center()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

extension SettingsWindowController: NSWindowDelegate {
  func windowDidBecomeKey(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
  }

  func windowWillClose(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }
}
