import AppKit
import Defaults
import SwiftUI

/// Notifications settings: which unblock-end events should produce a local notification.
struct NotificationsSettingsView: View {
  @Default var notifyWhenUnblockEnds: Bool
  @Default var notifyWhenDomainUnblockEnds: Bool
  @Default var notifyGravityUpdateCompleted: Bool

  @State private var permissionStatus: NotificationPermissionStatus?

  private let notificationCoordinator: NotificationCoordinator

  init(
    defaultsSuite: UserDefaults = .standard,
    notificationCoordinator: NotificationCoordinator
  ) {
    _notifyWhenUnblockEnds = .init(.notifyWhenUnblockEnds(suite: defaultsSuite))
    _notifyWhenDomainUnblockEnds = .init(.notifyWhenDomainUnblockEnds(suite: defaultsSuite))
    _notifyGravityUpdateCompleted = .init(.notifyGravityUpdateCompleted(suite: defaultsSuite))
    self.notificationCoordinator = notificationCoordinator
  }

  var body: some View {
    Group {
      if permissionStatus == .notAllowed {
        Section {
          permissionBanner
        }
      }

      Section("Notifications") {
        Toggle("Notify when an unblock timer ends", isOn: $notifyWhenUnblockEnds)
        Toggle("Notify when a domain unblock timer ends", isOn: $notifyWhenDomainUnblockEnds)
        Toggle("Notify when an in-app gravity update completes", isOn: $notifyGravityUpdateCompleted)
      }
    }
    .task {
      await refreshAuthorizationStatus()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
      guard (notification.object as? NSWindow)?.identifier?.rawValue == "Settings" else { return }
      Task { await refreshAuthorizationStatus() }
    }
  }

  private var permissionBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "bell.slash.fill")
        .foregroundColor(.orange)
      Text("Notifications are turned off for Holeberry.")
        .font(.callout)
        .foregroundColor(.secondary)
      Spacer()
      Button("Open System Settings…") {
        openNotificationSettings()
      }
      .controlSize(.small)
    }
    .padding(.vertical, 2)
  }

  private func refreshAuthorizationStatus() async {
    permissionStatus = await notificationCoordinator.notificationPermissionStatus()
  }

  /// Deep-links to this app's row in System Settings > Notifications.
  /// The `?id=` query is undocumented but is what shipped apps use (e.g. Vienna);
  /// without a bundle id it falls back to the Notifications pane itself.
  private func openNotificationSettings() {
    var components = URLComponents()
    components.scheme = "x-apple.systempreferences"
    components.path = "com.apple.Notifications-Settings.extension"
    if let bundleID = Bundle.main.bundleIdentifier {
      components.queryItems = [URLQueryItem(name: "id", value: bundleID)]
    }
    guard let url = components.url else { return }
    NSWorkspace.shared.open(url)
  }
}
