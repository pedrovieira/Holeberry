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
  private static let unblockFailureCategory = "UNBLOCK_FAILURE"

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
    case .gravityUpdateCompleted:
      content.body = "Gravity updated."
    case .gravityUpdatePartiallyCompleted(let failure):
      content.body = "Gravity partially updated."
      content.subtitle = "Server \(failure.serverName) failed with \(failure.category)"
    case .gravityUpdateFailedAll:
      content.body = "Gravity failed to update for all servers."
      content.subtitle = "Check your servers' connectivity."
    case .unblockFailed(let domain, let error):
      content.body = "Failed to unblock \(domain): \(error)"
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

  /// Schedules one aggregated notification for a gravity run: a completion
  /// banner when every server succeeded, a partial banner naming the failed
  /// server when some did, and a failure banner when none did.
  func scheduleGravityOutcomeNotifications(
    _ outcomes: [UUID: GravityUpdateOutcome],
    labelFor: (UUID) -> String?
  ) {
    guard !outcomes.isEmpty else { return }

    let succeededCount = outcomes.values.filter { $0 == .succeeded }.count
    if succeededCount == outcomes.count {
      schedule(.gravityUpdateCompleted)
      return
    }
    guard succeededCount > 0 else {
      schedule(.gravityUpdateFailedAll)
      return
    }

    // With the 2-server cap, a partial run has exactly one non-succeeded server.
    let failure = outcomes.compactMap { id, outcome -> (serverName: String, category: String)? in
      switch outcome {
      case .succeeded:
        return nil
      case .noChange:
        return (labelFor(id) ?? "Pi-hole", "no change detected")
      case .failed(let error):
        return (labelFor(id) ?? "Pi-hole", error.gravityErrorCategory)
      }
    }.first
    if let failure {
      schedule(.gravityUpdatePartiallyCompleted(failure: failure))
    }
  }

  // MARK: - Authorization

  /// Asks for permission once, while the status is still undetermined.
  /// Callers decide when asking is appropriate (e.g. once a server exists).
  func requestAuthorizationIfNeeded() {
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
    case .gravityUpdatePartiallyCompleted, .gravityUpdateFailedAll:
      // Always on — failures should never go unnoticed.
      return true
    case .gravityUpdateCompleted:
      return Defaults[.notifyGravityUpdateCompleted(suite: defaultsSuite)]
    case .unblockFailed:
      // Always on — failures should never go unnoticed.
      return true
    }
  }

  private static func category(for kind: UserNotificationKind) -> String {
    switch kind {
    case .shortcutError: return shortcutErrorCategory
    case .unblockEnded: return unblockEndedCategory
    case .domainUnblockEnded: return domainUnblockEndedCategory
    case .gravityUpdatePartiallyCompleted, .gravityUpdateFailedAll: return gravityErrorCategory
    case .gravityUpdateCompleted: return gravityCompletedCategory
    case .unblockFailed: return unblockFailureCategory
    }
  }

  private static func identifier(for kind: UserNotificationKind) -> String {
    let id = UUID().uuidString
    switch kind {
    case .shortcutError: return "shortcut-error-\(id)"
    case .unblockEnded: return "unblock-ended-\(id)"
    case .domainUnblockEnded: return "domain-unblock-ended-\(id)"
    case .gravityUpdatePartiallyCompleted, .gravityUpdateFailedAll: return "gravity-error-\(id)"
    case .gravityUpdateCompleted: return "gravity-completed-\(id)"
    case .unblockFailed: return "unblock-failed-\(id)"
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
    case Self.shortcutErrorCategory, Self.gravityErrorCategory, Self.unblockFailureCategory:
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

// MARK: - PiholeError category

extension PiholeError {
  /// Short category for the "Server … failed with …" notification subtext.
  var gravityErrorCategory: String {
    switch self {
    case .unauthorized, .invalidCredentials:
      return "authentication"
    case .network:
      return "network"
    case .server:
      return "server error"
    case .tlsUntrusted:
      return "untrusted certificate"
    case .duplicateDomain:
      return "duplicate domain"
    case .decoding:
      return "response parsing"
    case .totpRequired:
      return "2FA required"
    case .missingCredential:
      return "missing credential"
    case .rateLimited:
      return "rate limited"
    case .reauthenticationFailed:
      return "re-authentication failed"
    case .sessionLimitReached:
      return "session limit"
    case .unknown:
      return "unexpected error"
    case .unsupported:
      return "unsupported"
    }
  }
}
