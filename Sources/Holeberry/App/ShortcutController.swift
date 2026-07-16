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

    let firstError: String? = await withTaskGroup(of: String?.self) { group in
      for server in servers {
        group.addTask {
          do {
            try await self.serverManager.setBlocking(for: server.id, enabled: enabled, duration: duration)
            return nil
          } catch {
            self.logger.warning(
              """
              Shortcut setBlocking failed for \(server.label ?? server.url): \
              \(error.localizedDescription, privacy: .public)
              """
            )
            return error.localizedDescription
          }
        }
      }

      var firstError: String?
      for await result in group {
        if firstError == nil, let error = result {
          firstError = error
        }
      }
      return firstError
    }

    if let errorMessage = firstError {
      await postErrorNotification(action: enabled ? "enable" : "disable", error: errorMessage)
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

    // Show NSAlert with text field on main thread, then get the result
    let seconds = await MainActor.run { () -> TimeInterval? in
      let alert = NSAlert()
      alert.messageText = "Custom Disable Time"
      alert.informativeText = "Enter the number of seconds to disable blocking."
      alert.addButton(withTitle: "Disable")
      alert.addButton(withTitle: "Cancel")

      let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
      textField.placeholderString = "e.g. 120"
      alert.accessoryView = textField
      alert.window.initialFirstResponder = textField

      // Force synchronous layout before entering the modal run loop.
      // NSTextField lazily initializes its internal formatter/layout on first
      // layout, dispatching that work at Default QoS. Without this, the field can
      // appear blank or trigger a QoS inversion warning during runModal() on the
      // main thread.
      textField.layoutSubtreeIfNeeded()

      let response = alert.runModal()
      guard response == .alertFirstButtonReturn else { return nil }

      let text = textField.stringValue.trimmingCharacters(in: .whitespaces)
      guard let seconds = TimeInterval(text), seconds > 0 else { return nil }
      return seconds
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
