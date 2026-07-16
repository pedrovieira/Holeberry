import AppKit
import OSLog
import Sparkle
import SwiftUI
import UserNotifications

@main
struct HoleberryApp: App {
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
  private var updateManager: UpdateManager?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    // Request notification authorization for shortcut error alerts
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
      if let error {
        self.logger.warning("Notification authorization denied: \(error.localizedDescription, privacy: .public)")
      }
    }
    UNUserNotificationCenter.current().delegate = self

    // Start Sparkle updater
    let updaterManager = UpdateManager()
    self.updateManager = updaterManager
    SettingsWindowController.shared.setUpdater(updaterManager.updater)

    ServerStatusMonitor.shared.startPolling()

    let timerManager = TimerManager()
    let serverManager = PiholeServerManager.shared
    let reachability = ReachabilityMonitor()
    let statusMonitor = ServerStatusMonitor.shared
    let localIPAddressResolver = LocalIPAddressResolver()
    let appFocusMonitor = AppFocusMonitor()
    let browserUrlFetcher = BrowserUrlFetcher()
    let browserTabCoordinator = BrowserTabCoordinator(
      monitor: appFocusMonitor,
      urlFetcher: browserUrlFetcher
    )

    menuBarController = MenuBarController(
      timerManager: timerManager,
      serverManager: serverManager,
      reachability: reachability,
      statusMonitor: statusMonitor,
      browserTabCoordinator: browserTabCoordinator,
      localIPAddressResolver: localIPAddressResolver,
      updater: updaterManager.updater
    )
    shortcutController = ShortcutController(
      serverManager: serverManager,
      browserTabCoordinator: browserTabCoordinator
    )
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      do {
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask {
            await PiholeServerManager.shared.logoutAll()
          }
          group.addTask {
            try await Task.sleep(for: .seconds(5))
          }
          _ = try await group.next()
          group.cancelAll()
        }
      } catch {
        // timed out or cancelled — let the app quit anyway
      }
      await MainActor.run {
        NSApp.reply(toApplicationShouldTerminate: true)
      }
    }
    return .terminateLater
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
