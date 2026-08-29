import Foundation

/// The notification types Holeberry can produce.
///
/// Emission sites (ShortcutController, UnblockEndedNotifier, …) build a kind
/// and hand it to `NotificationCoordinator`, which owns everything about how
/// it becomes a system notification: settings gating, copy, category,
/// identifier, and sound.
enum UserNotificationKind {
  /// A shortcut-triggered blocking action failed on at least one server.
  case shortcutError(action: String, error: String)

  /// A global unblock ended on its own (blocking is active again).
  case unblockEnded(serverNames: [String])

  /// A temporary unblock for a specific domain expired on its own.
  case domainUnblockEnded(domain: String)

  /// A gravity update failed (request error, or the timestamp didn't move).
  case gravityUpdateFailed(serverName: String, error: String)

  /// A gravity update finished successfully.
  case gravityUpdateCompleted

  /// A temporary unblock of a domain failed.
  case unblockFailed(domain: String, error: String)
}
