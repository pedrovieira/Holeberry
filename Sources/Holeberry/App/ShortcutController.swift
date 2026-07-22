import AppKit
import Defaults
import KeyboardShortcuts
import OSLog
import UserNotifications

@MainActor
final class ShortcutController {
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "shortcuts")
  private let serverManager: PiholeServerManager
  private let browserTabCoordinator: BrowserTabCoordinator

  init(serverManager: PiholeServerManager, browserTabCoordinator: BrowserTabCoordinator) {
    self.serverManager = serverManager
    self.browserTabCoordinator = browserTabCoordinator
    registerShortcuts()
  }

  // MARK: - Registration

  private func registerShortcuts() {
    KeyboardShortcuts.onKeyDown(for: .disableIndefinitely) { [weak self] in
      Task { await self?.setBlockingOnAll(enabled: false, duration: nil) }
    }
    KeyboardShortcuts.onKeyDown(for: .disable10s) { [weak self] in
      Task { await self?.setBlockingOnAll(enabled: false, duration: 10) }
    }
    KeyboardShortcuts.onKeyDown(for: .disable30s) { [weak self] in
      Task { await self?.setBlockingOnAll(enabled: false, duration: 30) }
    }
    KeyboardShortcuts.onKeyDown(for: .disable5m) { [weak self] in
      Task { await self?.setBlockingOnAll(enabled: false, duration: 300) }
    }
    KeyboardShortcuts.onKeyDown(for: .disableCustom) { [weak self] in
      Task { await self?.promptCustomDurationThenSetBlocking() }
    }
    KeyboardShortcuts.onKeyDown(for: .reEnableBlocking) { [weak self] in
      Task { await self?.setBlockingOnAll(enabled: true, duration: nil) }
    }
    KeyboardShortcuts.onKeyDown(for: .unblockCurrentTab) { [weak self] in
      guard let self else { return }
      let result = self.browserTabCoordinator.requestPermissionAndResolve()
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
  }

  // MARK: - Blocking

  private func setBlockingOnAll(enabled: Bool, duration: TimeInterval?) async {
    let servers = serverManager.servers

    guard !servers.isEmpty else {
      logger.debug("Shortcut fired but no servers configured — skipping")
      return
    }

    let results = await serverManager.setBlocking(enabled: enabled, duration: duration)
    if let firstFailure = results.first(where: { !$0.value }) {
      let label = servers.first { $0.id == firstFailure.key }?.label ?? firstFailure.key.uuidString
      logger.warning("Shortcut setBlocking failed for \(label)")
      await postErrorNotification(action: enabled ? "enable" : "disable", error: "Failed for \(label)")
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
      await postErrorNotification(action: "unblock", error: error.localizedDescription)
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

  private func postErrorNotification(action: String, error: String) async {
    let content = UNMutableNotificationContent()
    content.title = "Holeberry"
    content.body = "Failed to \(action) blocking: \(error)"
    content.categoryIdentifier = "SHORTCUT_ERROR"
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: "shortcut-error-\(Date().timeIntervalSince1970)",
      content: content,
      trigger: nil
    )

    do {
      try await UNUserNotificationCenter.current().add(request)
    } catch {
      logger.error("Failed to post error notification: \(error.localizedDescription, privacy: .public)")
    }
  }
}
