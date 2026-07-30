import AppKit
import HoleberryCore
import Sparkle
import SwiftUI

final class SettingsWindowController: NSWindowController {
  let discoveryService: PiholeDiscoveryService
  private let serverManager: PiholeServerManager
  private let defaultsSuite: UserDefaults
  private var updater: SPUUpdater?
  private let statusPoller: ServerStatusPoller
  private var hasSetContentView = false

  init(
    serverManager: PiholeServerManager,
    updater: SPUUpdater?,
    discoveryService: PiholeDiscoveryService,
    statusPoller: ServerStatusPoller,
    defaultsSuite: UserDefaults = .standard
  ) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 580, height: 420),
      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    self.discoveryService = discoveryService
    self.serverManager = serverManager
    self.defaultsSuite = defaultsSuite
    self.updater = updater
    self.statusPoller = statusPoller
    super.init(window: window)
    setupWindow()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupWindow() {
    window?.title = "Settings"
    window?.identifier = NSUserInterfaceItemIdentifier("Settings")
    window?.titlebarAppearsTransparent = false
    window?.titleVisibility = .visible
    window?.toolbarStyle = .unified
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

    // Lazily create the NSHostingView the first time the window is shown.
    // With defer: false the window always has a default NSView as contentView,
    // so we track this with a boolean flag instead of checking for nil.
    if !hasSetContentView {
      window?.contentView = NSHostingView(
        rootView: SettingsView(
          serverManager: serverManager,
          updater: updater,
          defaultsSuite: defaultsSuite,
          discoveryService: discoveryService,
          statusPoller: statusPoller
        )
      )
      hasSetContentView = true
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
