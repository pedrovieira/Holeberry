import Defaults
import HoleberryCore
import OSLog
import UserNotifications

/// Whether Holeberry can present notifications, from the settings view's
/// perspective. Keeps `UNAuthorizationStatus` out of the UI layer.
enum NotificationPermissionStatus: Equatable {
  case authorized
  case notAllowed
}

/// The single owner of `UNUserNotificationCenter` in the app.
///
/// Every notification goes through `schedule(_:)` — including the settings
/// gating, copy, category, identifier, and sound. It also owns the delegate
/// (foreground presentation per category, click actions) and the
/// authorization request, so no other component needs to know about
/// `UserNotifications` at all.
@MainActor
final class NotificationCoordinator: NSObject {
  private static let shortcutErrorCategory = "SHORTCUT_ERROR"
  private static let unblockEndedCategory = "UNBLOCK_ENDED"
  private static let domainUnblockEndedCategory = "DOMAIN_UNBLOCK_ENDED"
  private static let gravityErrorCategory = "GRAVITY_ERROR"
  private static let gravityCompletedCategory = "GRAVITY_COMPLETED"

  private let defaultsSuite: UserDefaults
  private let openSettings: () -> Void
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "notifications")

  init(
    defaultsSuite: UserDefaults = .standard,
    openSettings: @escaping () -> Void
  ) {
    self.defaultsSuite = defaultsSuite
    self.openSettings = openSettings
    super.init()
    // This coordinator is the app's only UNUserNotificationCenterDelegate.
    UNUserNotificationCenter.current().delegate = self
  }

  // MARK: - Scheduling

  /// Builds and posts the system notification for `kind`, unless its settings
  /// toggle is off. Safe to call when authorization is missing — the system
  /// silently drops the request and nothing crashes.
  func schedule(_ kind: UserNotificationKind) {
    guard isEnabled(kind) else { return }

    let content = UNMutableNotificationContent()
    content.title = "Holeberry"
    content.categoryIdentifier = Self.category(for: kind)
    switch kind {
    case .shortcutError(let action, let error):
      content.body = "Failed to \(action) blocking: \(error)"
      content.sound = .default
    case .unblockEnded(let serverNames):
      content.body =
        serverNames.isEmpty
        ? "Blocking is active again."
        : "Blocking is active again on \(serverNames.joined(separator: ", "))."
    case .domainUnblockEnded(let domain):
      content.body = "\(domain) is blocked again."
    case .gravityUpdateFailed(let serverName, let error):
      content.body = "Failed to update gravity on \(serverName): \(error)"
      content.sound = .default
    case .gravityUpdateCompleted(let serverNames):
      content.body = "Gravity updated on \(serverNames.joined(separator: ", "))."
    }

    let request = UNNotificationRequest(
      identifier: Self.identifier(for: kind),
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request) { error in
      if let error {
        self.logger.warning(
          "Failed to deliver notification: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  // MARK: - Gravity outcomes

  /// Schedules notifications for gravity outcomes: one completion banner for
  /// the succeeded servers, plus a failure notification per failed server.
  func scheduleGravityOutcomeNotifications(
    _ outcomes: [UUID: GravityUpdateOutcome],
    labelFor: (UUID) -> String?
  ) {
    let completed = outcomes.compactMap { id, outcome in
      if case .succeeded = outcome { return labelFor(id) ?? "Pi-hole" }
      return nil
    }
    if !completed.isEmpty {
      schedule(.gravityUpdateCompleted(serverNames: completed))
    }
    for (id, outcome) in outcomes {
      switch outcome {
      case .failed(let error):
        schedule(.gravityUpdateFailed(serverName: labelFor(id) ?? "Pi-hole", error: error.localizedDescription))
      case .noChange:
        schedule(
          .gravityUpdateFailed(
            serverName: labelFor(id) ?? "Pi-hole",
            error: "Gravity finished but the update didn't take effect — check the Pi-hole web interface"
          )
        )
      case .succeeded:
        continue
      }
    }
  }

  // MARK: - Authorization

  /// Asks for permission once, and only when at least one server is configured
  /// (existing flows like unblock timers still need authorization).
  func requestAuthorizationIfNeeded() {
    guard !Defaults[.servers(suite: defaultsSuite)].isEmpty else { return }
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      guard settings.authorizationStatus == .notDetermined else { return }
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
        if let error {
          self.logger.warning(
            "Notification authorization failed: \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }
  }

  func notificationPermissionStatus() async -> NotificationPermissionStatus {
    switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
    case .authorized: return .authorized
    default: return .notAllowed
    }
  }

  // MARK: - Kind mapping

  private func isEnabled(_ kind: UserNotificationKind) -> Bool {
    switch kind {
    case .shortcutError:
      // Always on — failures should never go unnoticed. A settings toggle
      // can be added later if desired.
      return true
    case .unblockEnded:
      return Defaults[.notifyWhenUnblockEnds(suite: defaultsSuite)]
    case .domainUnblockEnded:
      return Defaults[.notifyWhenDomainUnblockEnds(suite: defaultsSuite)]
    case .gravityUpdateFailed:
      // Always on — failures should never go unnoticed.
      return true
    case .gravityUpdateCompleted:
      return Defaults[.notifyGravityUpdateCompleted(suite: defaultsSuite)]
    }
  }

  private static func category(for kind: UserNotificationKind) -> String {
    switch kind {
    case .shortcutError: return shortcutErrorCategory
    case .unblockEnded: return unblockEndedCategory
    case .domainUnblockEnded: return domainUnblockEndedCategory
    case .gravityUpdateFailed: return gravityErrorCategory
    case .gravityUpdateCompleted: return gravityCompletedCategory
    }
  }

  private static func identifier(for kind: UserNotificationKind) -> String {
    let id = UUID().uuidString
    switch kind {
    case .shortcutError: return "shortcut-error-\(id)"
    case .unblockEnded: return "unblock-ended-\(id)"
    case .domainUnblockEnded: return "domain-unblock-ended-\(id)"
    case .gravityUpdateFailed: return "gravity-error-\(id)"
    case .gravityUpdateCompleted: return "gravity-completed-\(id)"
    }
  }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationCoordinator: @preconcurrency UNUserNotificationCenterDelegate {
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    switch notification.request.content.categoryIdentifier {
    case Self.shortcutErrorCategory, Self.gravityErrorCategory:
      // An action the user triggered failed — alert them.
      completionHandler([.banner, .sound])
    default:
      // Informational: unblock-ended banners don't need a sound.
      completionHandler([.banner])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if response.notification.request.content.categoryIdentifier == Self.shortcutErrorCategory {
      openSettings()
    }
    completionHandler()
  }
}
