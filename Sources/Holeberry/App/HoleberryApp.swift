import AppKit
import Combine
import Defaults
import HoleberryCore
import OSLog
import Sparkle
import SwiftUI
import WidgetKit

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
  private var gravityCadenceScheduler: (any GravityCadenceScheduling)?
  private var wakeObserver: (any NSObjectProtocol)?
  private var notificationServerCancellable: AnyCancellable?
  private var cadenceCancellable: AnyCancellable?
  private var updaterController: SPUStandardUpdaterController?
  // Sparkle references its user-driver delegate weakly; keep it alive here.
  private var gentleUpdateReminderDelegate: GentleUpdateReminderDelegate?
  private var settingsWindowController: SettingsWindowController?
  private var pendingOpenSettingsFromWidget = false

  // MARK: - Composition Root (lazy var dependency graph)

  private lazy var appStorage = makeAppStorageContext()
  private lazy var authFactory = ConcreteAuthSessionFactory()
  private lazy var serviceFactory = ConcretePiholeServiceFactory(
    authSessionFactory: authFactory
  )
  private lazy var versionDetector = PiholeVersionDetector()
  private lazy var serverManager = PiholeServerManager(
    keychain: appStorage.keychain,
    serviceFactory: serviceFactory,
    versionDetector: versionDetector,
    suite: appStorage.suite
  ) {
    WidgetCenter.shared.reloadAllTimelines()
  }
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
  private lazy var permissionChecker = AutomationPermissionChecker()
  private lazy var scriptExecutor = LiveAppleScriptExecutor()
  private lazy var urlFetchingStrategyFactory = BrowserActiveUrlFetchingStrategyFactory(
    permissionChecker: permissionChecker,
    scriptExecutor: scriptExecutor
  )
  private lazy var browserTabCoordinator = BrowserTabCoordinator(
    monitor: appFocusMonitor,
    strategyFactory: urlFetchingStrategyFactory
  )
  private lazy var discoveryService = PiholeDiscoveryService(
    networkInterface: localIPResolver,
    dnsServerResolver: dnsServerResolver
  )

  // swiftlint:disable:next function_body_length
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    if appStorage.didMigrate {
      WidgetCenter.shared.reloadAllTimelines()
    }

    let notificationCoordinator = NotificationCoordinator(
      defaultsSuite: .standard,
      openSettings: { [weak self] in self?.settingsWindowController?.showWindow() },
      openUpdateAlert: { [weak self] in self?.updaterController?.checkForUpdates(nil) }
    )
    self.notificationCoordinator = notificationCoordinator
    let gravityOutcomeNotifier = GravityOutcomeNotifier(
      notificationCoordinator: notificationCoordinator,
      serverManager: serverManager
    )

    let gravityCadenceScheduler = LiveGravityCadenceScheduler(
      triggerUpdate: { [statusPoller] in await statusPoller.applyGravityUpdate() },
      onOutcomes: { [gravityOutcomeNotifier] outcomes in gravityOutcomeNotifier.notify(outcomes) }
    )
    self.gravityCadenceScheduler = gravityCadenceScheduler
    // React to cadence changes without coupling the settings UI to the scheduler.
    cadenceCancellable = Defaults.publisher(.gravityUpdateCadence(suite: .standard))
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.gravityCadenceScheduler?.cadenceDidChange()
      }
    requestNotificationAuthorizationIfNeeded()

    // A fresh prompt once the first server is added; authorization is asked
    // only while .notDetermined.
    notificationServerCancellable = serverManager.serversPublisher
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.requestNotificationAuthorizationIfNeeded()
      }

    // Start Sparkle updater with the standard UI and gentle reminders, so a
    // scheduled update in the background surfaces as a notification instead
    // of an alert the person may never notice.
    let gentleUpdateReminderDelegate = GentleUpdateReminderDelegate(
      notificationCoordinator: notificationCoordinator,
      isAutomaticUpdateCheckEnabled: { [weak self] in
        self?.updaterController?.updater.automaticallyChecksForUpdates ?? false
      },
      openUpdateAlert: { [weak self] in self?.updaterController?.checkForUpdates(nil) }
    )
    self.gentleUpdateReminderDelegate = gentleUpdateReminderDelegate
    let updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: gentleUpdateReminderDelegate
    )
    self.updaterController = updaterController

    let settingsWindowController = SettingsWindowController(
      serverManager: serverManager,
      updater: updaterController.updater,
      discoveryService: discoveryService,
      statusPoller: statusPoller,
      notificationCoordinator: notificationCoordinator,
      storageUnavailable: appStorage.storageUnavailable
    )
    self.settingsWindowController = settingsWindowController

    if pendingOpenSettingsFromWidget {
      pendingOpenSettingsFromWidget = false
      settingsWindowController.showWindow()
    }

    statusPoller.startPolling()

    // Catch up at launch and after wake (a one-shot task doesn't run while asleep).
    gravityCadenceScheduler.start()
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.gravityCadenceScheduler?.checkNow()
      }
    }

    menuBarController = MenuBarController(
      timerManager: timerManager,
      serverManager: serverManager,
      reachability: reachability,
      statusMonitor: statusPoller,
      browserTabCoordinator: browserTabCoordinator,
      localIPAddressResolver: localIPResolver,
      updater: updaterController.updater,
      notificationCoordinator: notificationCoordinator,
      gravityOutcomeNotifier: gravityOutcomeNotifier,
      settingsWindowController: settingsWindowController
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

  /// Asks for notification permission once a server is configured; the
  /// coordinator itself doesn't know about servers.
  private func requestNotificationAuthorizationIfNeeded() {
    guard !serverManager.servers.isEmpty else { return }
    notificationCoordinator?.requestAuthorizationIfNeeded()
  }

  /// A deliberate widget click opens the settings window instead of the hidden
  /// WindowGroup used to keep the SwiftUI app alive.
  func application(_ application: NSApplication, open urls: [URL]) {
    guard urls.contains(where: { $0.scheme == "holeberry" }) else { return }
    if let settingsWindowController {
      settingsWindowController.showWindow()
    } else {
      pendingOpenSettingsFromWidget = true
    }
  }

  private func makeAppStorageContext() -> AppStorageContext {
    let legacySuite: UserDefaults = .standard
    let legacyKeychain = KeychainManager()

    let appGroupIdentifier: String
    let keychainAccessGroup: String
    do {
      appGroupIdentifier = try Bundle.main.sharedAppGroupIdentifier()
      keychainAccessGroup = try Bundle.main.sharedKeychainAccessGroup()
    } catch {
      logger.error("Shared storage configuration failed: \(error.localizedDescription, privacy: .public)")
      return unavailableStorageContext()
    }

    let sharedKeychain = KeychainManager.shared(
      accessGroup: keychainAccessGroup,
      interactive: true
    )
    let selection = AppStorageStartup.select(
      isActivated: Defaults[.sharedStorageActivated(suite: legacySuite)],
      resolve: {
        try UserDefaults.sharedStorageSuite(appGroupIdentifier: appGroupIdentifier)
      },
      migrate: { sharedSuite in
        do {
          try SharedStorageMigration(
            legacySuite: legacySuite,
            sharedSuite: sharedSuite,
            sharedSuiteName: appGroupIdentifier,
            legacyKeychain: legacyKeychain,
            sharedKeychain: sharedKeychain
          ).migrate()
        } catch {
          logger.error("Shared storage migration failed: \(error.localizedDescription, privacy: .public)")
          throw error
        }
      },
      markActivated: {
        Defaults[.sharedStorageActivated(suite: legacySuite)] = true
      }
    )

    switch selection {
    case .useShared(let suite, let didMigrate):
      return AppStorageContext(
        suite: suite,
        keychain: sharedKeychain,
        didMigrate: didMigrate,
        storageUnavailable: false
      )
    case .unavailable:
      logger.error("Shared storage unavailable; server changes are disabled for this launch.")
      return unavailableStorageContext()
    }
  }

  private func unavailableStorageContext() -> AppStorageContext {
    AppStorageContext(
      suite: UnavailableDefaults.shared,
      keychain: UnavailableKeychain(),
      didMigrate: false,
      storageUnavailable: true
    )
  }

  private struct AppStorageContext {
    let suite: UserDefaults
    let keychain: any KeychainManaging
    let didMigrate: Bool
    let storageUnavailable: Bool
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      do {
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask {
            await self.serverManager.logoutAll()
          }
          group.addTask {
            try await sleepForSeconds(5)
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
