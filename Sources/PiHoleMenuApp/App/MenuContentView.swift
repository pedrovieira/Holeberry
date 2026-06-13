import OSLog
import SwiftUI

struct MenuContentView: View {
  @StateObject private var manager = PiholeServerManager()
  @EnvironmentObject private var timerManager: TimerManager
  @State private var statusError: String?
  @State private var isPolling = false

  private let logger = Logger(subsystem: Logger.appSubsystem, category: "menu-content")
  private let pollInterval: TimeInterval = 30

  var body: some View {
    VStack {
      if manager.servers.isEmpty {
        emptyState
      } else {
        statusRow
        Divider()
        blockingControls
        Divider()
        recentBlockedSection
        Divider()
        settingsAndQuit
      }
    }
    .onAppear {
      pollStatus()
    }
    .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
      manager.reloadServers()
    }
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack {
      Text("No instances configured")
        .foregroundColor(.secondary)
      Text("Open Settings to add a Pi-hole")
        .font(.caption)
        .foregroundColor(.secondary)
      Divider()
      Button("Settings...") {
        SettingsWindowController.shared.showWindow()
      }
      .keyboardShortcut(",")
      Divider()
      Button("Quit") {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }
  }

  // MARK: - Status Row

  private var statusRow: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Circle()
          .fill(statusColor)
          .frame(width: 8, height: 8)
        Text(statusText)
          .font(.system(size: 12, weight: .medium))
      }
      if let error = statusError {
        Text(error)
          .font(.caption)
          .foregroundColor(.red)
      }
      Text("\(manager.servers.count) instance(s) configured")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .padding(.vertical, 2)
  }

  private var statusColor: Color {
    if statusError != nil { return .red }
    if timerManager.isDisabled { return .orange }
    return .green
  }

  private var statusText: String {
    if statusError != nil { return "Connection Error" }
    if timerManager.isDisabled { return "Blocking Disabled" }
    return "Blocking Active"
  }

  // MARK: - Blocking Controls

  private var blockingControls: some View {
    VStack(spacing: 0) {
      if timerManager.isDisabled {
        Button("Re-Enable Blocking") {
          enableBlocking()
        }
      } else {
        Menu("Disable Blocking") {
          Button("Indefinitely") {
            disableBlocking(duration: nil)
          }
          Button("10 seconds") {
            disableBlocking(duration: 10)
          }
          Button("30 seconds") {
            disableBlocking(duration: 30)
          }
          Button("5 minutes") {
            disableBlocking(duration: 300)
          }
          Divider()
          Button("Custom...") {
            promptCustomTime()
          }
        }
      }
    }
  }

  // MARK: - Recent Blocked (Placeholder)

  private var recentBlockedSection: some View {
    Menu("Recent Blocked") {
      Text("Fetch on demand")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Settings & Quit

  private var settingsAndQuit: some View {
    VStack(spacing: 0) {
      Button("Settings...") {
        SettingsWindowController.shared.showWindow()
      }
      .keyboardShortcut(",")

      Button("Quit") {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }
  }

  // MARK: - Actions

  private func disableBlocking(duration: TimeInterval?) {
    guard let server = manager.servers.first, server.version != nil else {
      statusError = "No configured Pi-hole instance"
      clearErrorAfterDelay()
      return
    }
    Task {
      do {
        try await manager.setBlocking(for: server, enabled: false, duration: duration)
        await MainActor.run {
          timerManager.startDisable(duration: duration)
          statusError = nil
        }
      } catch {
        await MainActor.run {
          statusError = error.localizedDescription
          clearErrorAfterDelay()
        }
      }
    }
  }

  private func enableBlocking() {
    guard let server = manager.servers.first, server.version != nil else {
      statusError = "No configured Pi-hole instance"
      clearErrorAfterDelay()
      return
    }
    Task {
      do {
        try await manager.setBlocking(for: server, enabled: true, duration: nil)
        await MainActor.run {
          timerManager.cancelDisable()
          statusError = nil
        }
      } catch {
        await MainActor.run {
          statusError = error.localizedDescription
          clearErrorAfterDelay()
        }
      }
    }
  }

  private func promptCustomTime() {
    let alert = NSAlert()
    alert.messageText = "Custom Disable Time"
    alert.informativeText = "Enter the number of seconds to disable blocking."
    alert.addButton(withTitle: "Disable")
    alert.addButton(withTitle: "Cancel")

    let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    textField.placeholderString = "e.g. 120"
    alert.accessoryView = textField
    textField.becomeFirstResponder()

    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
      let text = textField.stringValue.trimmingCharacters(in: .whitespaces)
      if let seconds = TimeInterval(text), seconds > 0 {
        disableBlocking(duration: seconds)
      }
    }
  }

  // MARK: - Polling

  private func pollStatus() {
    guard !isPolling, let server = manager.servers.first, server.version != nil else { return }
    isPolling = true
    Task {
      defer { isPolling = false }
      do {
        let status = try await manager.getBlockingStatus(for: server)
        await MainActor.run {
          timerManager.syncFromRemote(status)
          statusError = nil
        }
      } catch {
        logger.warning("Status poll failed: \(error.localizedDescription, privacy: .public)")
        await MainActor.run {
          statusError = error.localizedDescription
          clearErrorAfterDelay()
        }
      }
    }
  }

  private func clearErrorAfterDelay() {
    Task {
      try? await Task.sleep(for: .seconds(3))
      await MainActor.run {
        statusError = nil
      }
    }
  }
}
