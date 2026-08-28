import AppKit
import HoleberryCore
import OSLog
import Sparkle
import SwiftUI

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
  private var unblockEndedNotifier: UnblockEndedNotifier?
  private var notificationCoordinator: NotificationCoordinator?
  private var updateManager: UpdateManager?
  private var settingsWindowController: SettingsWindowController?

  // MARK: - Composition Root (lazy var dependency graph)

  private lazy var keychain = KeychainManager()
  private lazy var htmlParser: any PiholeV5HTMLParsing = PiholeV5HTMLParser()
  private lazy var authFactory = ConcreteAuthSessionFactory()
  private lazy var serviceFactory = ConcretePiholeServiceFactory(
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
  private lazy var dnsServerResolver = EffectiveDNSServerResolver()
  private lazy var pollScheduler = TaskPollScheduler()
  private lazy var gravityUpdater = LiveGravityUpdater(manager: serverManager)
  private lazy var statusPoller = ServerStatusPoller(
    manager: serverManager,
    networkInterface: localIPResolver,
    pollingInterval: 30,
    scheduler: pollScheduler,
    timerManager: timerManager,
    gravityUpdater: gravityUpdater
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
  private lazy var discoveryService = PiholeDiscoveryService(
    networkInterface: localIPResolver,
    dnsServerResolver: dnsServerResolver
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    let notificationCoordinator = NotificationCoordinator(defaultsSuite: .standard) { [weak self] in
      self?.settingsWindowController?.showWindow()
    }
    self.notificationCoordinator = notificationCoordinator
    notificationCoordinator.requestAuthorizationIfNeeded()

    // Start Sparkle updater
    let updaterManager = UpdateManager()
    self.updateManager = updaterManager

    let settingsWindowController = SettingsWindowController(
      serverManager: serverManager,
      updater: updaterManager.updater,
      discoveryService: discoveryService,
      statusPoller: statusPoller,
      notificationCoordinator: notificationCoordinator
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
      settingsWindowController: settingsWindowController,
      notificationCoordinator: notificationCoordinator
    )
    shortcutController = ShortcutController(
      serverManager: serverManager,
      browserTabCoordinator: browserTabCoordinator,
      statusMonitor: statusPoller,
      notificationCoordinator: notificationCoordinator
    )
    unblockEndedNotifier = UnblockEndedNotifier(
      statusMonitor: statusPoller,
      serverManager: serverManager,
      notificationCoordinator: notificationCoordinator
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
            try await Task.sleep(nanoseconds: UInt64(5 * 1_000_000_000))
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
