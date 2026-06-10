import AppKit
import SwiftUI

@main
struct PiHoleMenuApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self)
  var appDelegate

  var body: some Scene {
    MenuBarExtra {
      MenuContentView()
    } label: {
      Label("Pi-hole", systemImage: "shield")
    }
  }
}

class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }
}
