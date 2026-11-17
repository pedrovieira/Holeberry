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
  private lazy var serverManager: PiholeServerManager = {
    let writesSharedStore = appStorage.startupStatus == .shared
    return PiholeServerManager(
      storage: appStorage.storage,
      serviceFactory: serviceFactory,
      versionDetector: versionDetector,
      allowsServerChanges: appStorage.allowsServerChanges
    ) {
      guard writesSharedStore else { return }
      WidgetCenter.shared.reloadAllTimelines()
    }
  }()
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

    // Initialize shared storage before widgets read it, then refresh every widget
    // kind only when this launch just migrated the stores. Server and credential
    // changes reload through the manager's persistent change handler instead.
    _ = appStorage
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
      startupStatus: appStorage.startupStatus
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
    guard urls.contains(where: { $0.scheme == AppDeepLink.scheme }) else { return }
    if let settingsWindowController {
      settingsWindowController.showWindow()
    } else {
      pendingOpenSettingsFromWidget = true
    }
  }

  private func makeAppStorageContext() -> AppStorageContext {
    let legacySuite: UserDefaults = .standard
    let legacyKeychain = KeychainManager()
    let readActivatedVersion: () throws -> Int = {
      try SharedStorageMigration.activatedVersion(
        in: legacySuite,
        suiteName: try self.activationSuiteName()
      )
    }

    // Check completion before opening the shared Keychain.
    let appGroupIdentifier: String
    do {
      appGroupIdentifier = try Bundle.main.sharedAppGroupIdentifier()
    } catch {
      logger.error("App Group identifier unavailable: \(error.localizedDescription, privacy: .public)")
      let selection = AppStorageStartup.select(
        readActivatedVersion: readActivatedVersion,
        resolve: { throw error },
        readReadiness: { _ in .pending },
        migrate: { _ in },
        markActivated: {}
      )
      return makeContext(selection: selection, legacySuite: legacySuite, legacyKeychain: legacyKeychain)
    }

    let selection = AppStorageStartup.select(
      readActivatedVersion: readActivatedVersion,
      resolve: {
        try UserDefaults.sharedStorageSuite(appGroupIdentifier: appGroupIdentifier)
      },
      readReadiness: { sharedSuite in
        try SharedStorageMigration.readiness(in: sharedSuite, suiteName: appGroupIdentifier)
      },
      migrate: { sharedSuite in
        do {
          try SharedStorageMigration(
            legacySuite: legacySuite,
            sharedSuite: sharedSuite,
            sharedSuiteName: appGroupIdentifier,
            legacyKeychain: legacyKeychain,
            sharedKeychain: try makeSharedKeychain()
          ).migrate()
        } catch {
          logger.error("Shared storage migration failed: \(error.localizedDescription, privacy: .public)")
          throw error
        }
      },
      markActivated: {
        try SharedStorageMigration.markActivated(
          in: legacySuite,
          suiteName: try activationSuiteName()
        )
      }
    )
    return makeContext(selection: selection, legacySuite: legacySuite, legacyKeychain: legacyKeychain)
  }

  private func makeContext(
    selection: AppStorageStartupSelection,
    legacySuite: UserDefaults,
    legacyKeychain: KeychainManager
  ) -> AppStorageContext {
    switch selection {
    case .useShared(let sharedSuite, let didMigrate):
      let sharedKeychain: KeychainManager
      do {
        sharedKeychain = try makeSharedKeychain()
      } catch {
        logger.error(
          "Shared Keychain unavailable for a completed store: \(error.localizedDescription, privacy: .public)")
        return unavailableStorageContext()
      }
      return AppStorageContext(
        storage: ConcreteAppStorage(
          sharedDataSuite: sharedSuite,
          appLocalSuite: .standard,
          keychain: sharedKeychain
        ),
        didMigrate: didMigrate,
        startupStatus: .shared,
        allowsServerChanges: true
      )
    case .useLegacy(let cause):
      logger.error(
        "Cutover pending; using legacy storage for this launch: \(cause.localizedDescription, privacy: .public)")
      return AppStorageContext(
        storage: ConcreteAppStorage(
          sharedDataSuite: legacySuite,
          appLocalSuite: legacySuite,
          keychain: legacyKeychain
        ),
        didMigrate: false,
        startupStatus: selection.status,
        allowsServerChanges: selection.allowsServerChanges
      )
    case .unavailable(let cause):
      logger.error("Shared storage unavailable; no-write state: \(cause.localizedDescription, privacy: .public)")
      return unavailableStorageContext()
    }
  }

  private func unavailableStorageContext() -> AppStorageContext {
    let storage = ConcreteAppStorage(
      sharedDataSuite: UnavailableDefaults.shared,
      appLocalSuite: .standard,
      keychain: UnavailableKeychain()
    )
    return AppStorageContext(
      storage: storage,
      didMigrate: false,
      startupStatus: .recovery,
      allowsServerChanges: false
    )
  }

  private func makeSharedKeychain() throws -> KeychainManager {
    try KeychainManager.shared(
      accessGroup: Bundle.main.sharedKeychainAccessGroup(), interactive: true)
  }

  /// The persistent domain behind `UserDefaults.standard`.
  private func activationSuiteName() throws -> String {
    guard let identifier = Bundle.main.bundleIdentifier else {
      throw SharedStorageMigrationError.activationRecordNotPersisted
    }
    return identifier
  }

  private struct AppStorageContext {
    let storage: any AppStorageProviding
    let didMigrate: Bool
    let startupStatus: AppStorageStartupStatus
    let allowsServerChanges: Bool
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
