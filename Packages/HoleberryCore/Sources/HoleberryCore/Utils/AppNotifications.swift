import Foundation

// MARK: - App Notification Names
//
// The single home for every NotificationCenter event that flows from
// HoleberryCore to the app layer. Services post these; the app observes
// them. User-facing UN notifications are a separate concern (see the app
// target's NotificationCoordinator).

extension Notification.Name {
  /// Posted when a temporary domain unblock expires on its own — the domain
  /// was re-blocked automatically. Manual removals and init-time
  /// reconciliation never post. Payload: `AppNotificationUserInfoKey.domain`.
  public static let domainUnblockExpired = Notification.Name("domainUnblockExpired")
}

/// `userInfo` keys for app notifications. Prefer these over string literals.
public enum AppNotificationUserInfoKey {
  /// The affected domain (String).
  public static let domain = "domain"

  /// The server's base URL string.
  public static let serverURL = "serverURL"
}
