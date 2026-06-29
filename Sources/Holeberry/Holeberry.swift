import AppKit
import OSLog
import SwiftUI
import UserNotifications

@main
struct Holeberry: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self)
  var appDelegate

  var body: some Scene {
    WindowGroup(id: "hidden") {
      Color.clear
        .frame(width: 0, height: 0)
        .hidden()
    }
    .windowResizability(.contentSize)
    .defaultSize(width: 0, height: 0)
  }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "app-delegate")
  private var menuBarController: MenuBarController?
  private var shortcutController: ShortcutController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    // Request notification authorization for shortcut error alerts
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
      if let error {
        self.logger.warning("Notification authorization denied: \(error.localizedDescription, privacy: .public)")
      }
    }
    UNUserNotificationCenter.current().delegate = self

    ServerStatusMonitor.shared.startPolling()
    menuBarController = MenuBarController(tempUnblockManager: .shared)
    shortcutController = ShortcutController()
  }

  func applicationWillTerminate(_ notification: Notification) {
    Task {
      await ServerStatusMonitor.shared.logoutAll()
    }
  }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // Show notification even when app is in foreground
    completionHandler([.banner, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if response.notification.request.content.categoryIdentifier == "SHORTCUT_ERROR" {
      SettingsWindowController.shared.showWindow()
    }
    completionHandler()
  }
}
