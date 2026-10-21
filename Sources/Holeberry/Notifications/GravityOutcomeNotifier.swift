import Foundation
import HoleberryCore

/// Turns gravity outcomes into notifications; shared by the manual action
/// and cadence runs.
@MainActor
struct GravityOutcomeNotifier {
  private let notificationCoordinator: NotificationCoordinator
  private let serverLabel: (UUID) -> String?

  init(
    notificationCoordinator: NotificationCoordinator,
    serverManager: PiholeServerManager
  ) {
    self.notificationCoordinator = notificationCoordinator
    self.serverLabel = serverManager.displayLabel(for:)
  }

  func notify(_ outcomes: [UUID: GravityUpdateOutcome]) {
    notificationCoordinator.scheduleGravityOutcomeNotifications(outcomes) { [serverLabel] id in
      serverLabel(id)
    }
  }
}
