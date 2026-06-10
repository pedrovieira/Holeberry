import AppKit
import SwiftUI

@main
struct PiHoleMenuApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self)
  var appDelegate

  var body: some Scene {
    Settings {
      Text("Settings")
        .frame(width: 300, height: 200)
    }
  }
}

class AppDelegate: NSObject, NSApplicationDelegate {
  private var menuBarController: MenuBarController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    menuBarController = MenuBarController()
  }
}
