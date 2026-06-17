import AppKit
import KeyboardShortcuts
import OSLog
import UserNotifications

@MainActor
final class ShortcutController {
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "shortcuts")

  init() {
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
  }

  // MARK: - Blocking

  private func setBlockingOnAll(enabled: Bool, duration: TimeInterval?) async {
    let monitor = ServerStatusMonitor.shared
    let servers = monitor.servers

    guard !servers.isEmpty else {
      logger.debug("Shortcut fired but no servers configured — skipping")
      return
    }

    var firstError: String?
    for server in servers {
      do {
        try await monitor.setBlocking(for: server, enabled: enabled, duration: duration)
      } catch {
        logger.warning(
          "Shortcut setBlocking failed for \(server.label ?? server.url): \(error.localizedDescription, privacy: .public)"
        )
        if firstError == nil {
          firstError = error.localizedDescription
        }
      }
    }

    if let errorMessage = firstError {
      await postErrorNotification(action: enabled ? "enable" : "disable", error: errorMessage)
    }
  }

  // MARK: - Custom Duration

  private func promptCustomDurationThenSetBlocking() async {
    let monitor = ServerStatusMonitor.shared
    guard !monitor.servers.isEmpty else {
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
    content.title = "Pi-hole Menu Bar"
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
