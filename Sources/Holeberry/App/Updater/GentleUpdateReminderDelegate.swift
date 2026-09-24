import Sparkle

/// Sparkle gentle scheduled-update reminders.
///
/// Holeberry runs as a menu-bar-only (background) application. Without this
/// delegate, Sparkle warns that a scheduled update alert for a background app
/// can go unnoticed — the alert is shown without activating the app. With
/// gentle reminders, checks Sparkle proposes to show in immediate focus
/// (within seconds of launch) still take focus, and everything else becomes
/// an "update available" notification instead. When notifications cannot be
/// delivered, the pending alert is brought into focus instead, so a
/// discovered update is never left invisible.
///
/// Sparkle holds its user-driver delegate weakly; `AppDelegate` keeps this
/// object alive.
@MainActor
final class GentleUpdateReminderDelegate: NSObject {
  private let notificationCoordinator: NotificationCoordinator
  private let isAutomaticUpdateCheckEnabled: () -> Bool
  private let openUpdateAlert: () -> Void

  init(
    notificationCoordinator: NotificationCoordinator,
    isAutomaticUpdateCheckEnabled: @escaping () -> Bool,
    openUpdateAlert: @escaping () -> Void
  ) {
    self.notificationCoordinator = notificationCoordinator
    self.isAutomaticUpdateCheckEnabled = isAutomaticUpdateCheckEnabled
    self.openUpdateAlert = openUpdateAlert
    super.init()
  }
}

// MARK: - SPUStandardUserDriverDelegate

extension GentleUpdateReminderDelegate: @preconcurrency SPUStandardUserDriverDelegate {
  /// Declares gentle reminder support; Sparkle logs a warning for background
  /// apps that auto-check for updates without it.
  var supportsGentleScheduledUpdateReminders: Bool { true }

  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem,
    andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    // Within seconds of launch Sparkle proposes to show the alert in
    // immediate focus — let it. For everything else this delegate handles
    // showing the update.
    immediateFocus
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    // Only act when this delegate took over showing (scheduled checks
    // Sparkle does not bring into focus) and the person still wants
    // automatic update checks. Sparkle shows user-initiated checks itself.
    guard !handleShowingUpdate, isAutomaticUpdateCheckEnabled() else { return }
    Task { @MainActor in
      // Read the permission fresh instead of caching it — the person may
      // have granted or revoked it since the last check.
      if await notificationCoordinator.notificationPermissionStatus() == .authorized {
        notificationCoordinator.schedule(.updateAvailable(version: update.displayVersionString))
      } else {
        // The reminder cannot reach anyone; bring Sparkle's pending alert
        // into focus instead.
        openUpdateAlert()
      }
    }
  }

  /// The update got the person's attention through another path (e.g. the
  /// menu's "Check for Updates…", or installing) — drop a stale reminder.
  func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    notificationCoordinator.withdrawUpdateReminder()
  }
}
