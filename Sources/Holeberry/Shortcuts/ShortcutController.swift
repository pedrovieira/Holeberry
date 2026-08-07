import AppKit
import Combine
import Defaults
import HoleberryCore
import KeyboardShortcuts
import OSLog

@MainActor
final class ShortcutController {
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "shortcuts")
  private let serverManager: PiholeServerManager
  private let browserTabCoordinator: BrowserTabCoordinator
  private let statusMonitor: ServerStatusPoller
  private let notificationCoordinator: NotificationCoordinator
  private let defaultsSuite: UserDefaults
  private var registeredDurationNames = Set<KeyboardShortcuts.Name>()
  private var everRegisteredDurationNames = Set<KeyboardShortcuts.Name>()
  private var cancellables = Set<AnyCancellable>()

  init(
    serverManager: PiholeServerManager,
    browserTabCoordinator: BrowserTabCoordinator,
    statusMonitor: ServerStatusPoller,
    notificationCoordinator: NotificationCoordinator,
    defaultsSuite: UserDefaults = .standard
  ) {
    self.serverManager = serverManager
    self.browserTabCoordinator = browserTabCoordinator
    self.statusMonitor = statusMonitor
    self.notificationCoordinator = notificationCoordinator
    self.defaultsSuite = defaultsSuite
    registerShortcuts()
  }

  // MARK: - Registration

  private func registerShortcuts() {
    KeyboardShortcuts.onKeyDown(for: .disableIndefinitely) { [weak self] in
      Task { await self?.setBlockingOnAll(enabled: false, duration: nil) }
    }
    KeyboardShortcuts.onKeyDown(for: .disableCustom) { [weak self] in
      Task { await self?.promptCustomDurationThenSetBlocking() }
    }
    KeyboardShortcuts.onKeyDown(for: .reEnableBlocking) { [weak self] in
      Task { await self?.setBlockingOnAll(enabled: true, duration: nil) }
    }
    KeyboardShortcuts.onKeyDown(for: .unblockCurrentTab) { [weak self] in
      guard let self else { return }
      let result = self.browserTabCoordinator.requestPermissionIfNeededAndResolve()
      if case .permissionDenied = result {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Automation") {
          NSWorkspace.shared.open(url)
        }
        return
      }
      guard case .url(_, let domain) = result else {
        logger.debug("Unblock current tab shortcut: no URL available (\(String(describing: result)))")
        return
      }
      Task {
        await self.unblockOnAllServers(domain: domain, duration: 300)
      }
    }

    registerDurationShortcuts()

    Defaults.publisher(.unblockDurations(suite: defaultsSuite))
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.registerDurationShortcuts()
      }
      .store(in: &cancellables)
  }

  /// Registers one handler per stored duration and resets shortcuts that
  /// were removed. Idempotent: a name is only ever registered once per
  /// process, because the KeyboardShortcuts library appends handlers and
  /// has no removal API — re-registering a name would double-fire.
  /// Entries are immutable, so a stable id always maps to the same seconds
  /// value and the original handler remains correct.
  private func registerDurationShortcuts() {
    let entries = Defaults[.unblockDurations(suite: defaultsSuite)]
    let currentNames = Set(entries.map { KeyboardShortcuts.Name.durationShortcutName(for: $0) })

    for entry in entries {
      let name = KeyboardShortcuts.Name.durationShortcutName(for: entry)
      guard !everRegisteredDurationNames.contains(name) else { continue }
      KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
        Task { await self?.setBlockingOnAll(enabled: false, duration: entry.seconds) }
      }
      registeredDurationNames.insert(name)
      everRegisteredDurationNames.insert(name)
    }

    for name in registeredDurationNames.subtracting(currentNames) {
      KeyboardShortcuts.reset(name)
      registeredDurationNames.remove(name)
    }
  }

  // MARK: - Blocking

  private func setBlockingOnAll(enabled: Bool, duration: TimeInterval?) async {
    let servers = serverManager.servers

    guard !servers.isEmpty else {
      logger.debug("Shortcut fired but no servers configured — skipping")
      return
    }

    // Route through the same funnel as the menu so the menu-bar dot and
    // countdown pill reflect the change immediately instead of at the next
    // poll (up to 30s later). Timer management is the poller's job.
    let results = await statusMonitor.applyBlockingChange(enabled: enabled, duration: duration)
    if let firstFailure = results.first(where: { !$0.value }) {
      let label = servers.first { $0.id == firstFailure.key }?.label ?? firstFailure.key.uuidString
      logger.warning("Shortcut setBlocking failed for \(label)")
      postErrorNotification(action: enabled ? "enable" : "disable", error: "Failed for \(label)")
    }
  }

  private func unblockOnAllServers(domain: String, duration: TimeInterval) async {
    guard !serverManager.servers.isEmpty else {
      logger.debug("Unblock shortcut fired but no servers configured — skipping")
      return
    }

    do {
      try await serverManager.unblock(domain: domain, duration: duration)
    } catch {
      logger.warning(
        """
        Shortcut unblock failed: \
        \(error.localizedDescription, privacy: .public)
        """
      )
      postErrorNotification(action: "unblock", error: error.localizedDescription)
    }
  }

  // MARK: - Custom Duration

  private func promptCustomDurationThenSetBlocking() async {
    guard !serverManager.servers.isEmpty else {
      logger.debug("disableCustom shortcut fired but no servers configured — skipping")
      return
    }

    // Show DurationPickerAlert on main thread, then get the result
    let seconds = await MainActor.run { () -> TimeInterval? in
      let alert = DurationPickerAlert(
        title: "Custom Disable Time",
        message: "Choose how long to disable blocking.",
        confirmButton: "Disable"
      )
      return alert.runDurationPicker()
    }

    guard let duration = seconds else { return }
    await setBlockingOnAll(enabled: false, duration: duration)
  }

  // MARK: - Error Notification

  private func postErrorNotification(action: String, error: String) {
    notificationCoordinator.schedule(.shortcutError(action: action, error: error))
  }
}
