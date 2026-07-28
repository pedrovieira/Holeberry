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
  private var settingsWindowController: SettingsWindowController?

  // MARK: - Composition Root (lazy var dependency graph)

  private lazy var keychain = KeychainManager()
  private lazy var htmlParser: PiholeV5HTMLParsing = PiholeV5HTMLParser()
  private lazy var authFactory = ConcreteAuthSessionFactory()
  private lazy var serviceFactory = PiholeServiceFactory(
    authSessionFactory: authFactory,
    htmlParser: htmlParser
  )
  private lazy var versionDetector = PiholeVersionDetector()
  private lazy var serverManager = PiholeServerManager(
    keychain: keychain,
    serviceFactory: serviceFactory,
    versionDetector: versionDetector
  )
  private lazy var localIPResolver = LocalIPAddressResolver()
  private lazy var statusPoller = ServerStatusPoller(
    manager: serverManager,
    networkInterface: localIPResolver
  )
  private lazy var reachability = ReachabilityMonitor()
  private lazy var timerManager = TimerManager()
  private lazy var appFocusMonitor = AppFocusMonitor(
    notificationCenter: NSWorkspace.shared.notificationCenter
  ) { notification in
    (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
  }
  private lazy var permissionChecker = LivePermissionChecker()
  private lazy var scriptExecutor = LiveAppleScriptExecutor()
  private lazy var urlFetchingStrategyFactory = BrowserActiveUrlFetchingStrategyFactory(
    permissionChecker: permissionChecker,
    scriptExecutor: scriptExecutor
  )
  private lazy var browserUrlFetcher = BrowserUrlFetcher(strategyFactory: urlFetchingStrategyFactory)
  private lazy var browserTabCoordinator = BrowserTabCoordinator(
    monitor: appFocusMonitor,
    urlFetcher: browserUrlFetcher,
    strategyFactory: urlFetchingStrategyFactory
  )
  private lazy var discoveryService = PiholeDiscoveryService(networkInterface: localIPResolver)

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

    let settingsWindowController = SettingsWindowController(
      serverManager: serverManager,
      updater: updaterManager.updater,
      discoveryService: discoveryService,
      statusPoller: statusPoller
    )
    self.settingsWindowController = settingsWindowController

    statusPoller.startPolling()

    menuBarController = MenuBarController(
      timerManager: timerManager,
      serverManager: serverManager,
      reachability: reachability,
      statusMonitor: statusPoller,
      browserTabCoordinator: browserTabCoordinator,
      localIPAddressResolver: localIPResolver,
      updater: updaterManager.updater,
      settingsWindowController: settingsWindowController
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
            await self.serverManager.logoutAll()
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
      settingsWindowController?.showWindow()
    }
    completionHandler()
  }
}
