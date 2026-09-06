import Foundation
import HoleberryCore

/// Turns gravity update outcomes into user notifications. Shared by the
/// manual menu action and automatic cadence runs so both are
/// indistinguishable to the user.
@MainActor
struct GravityOutcomeNotifier {
  private let notificationCoordinator: NotificationCoordinator
  private let serverLabel: (UUID) -> String?

  init(
    notificationCoordinator: NotificationCoordinator,
    serverManager: PiholeServerManager
  ) {
    self.notificationCoordinator = notificationCoordinator
    self.serverLabel = { id in serverManager.servers.first { $0.id == id }?.label }
  }

  func notify(_ outcomes: [UUID: GravityUpdateOutcome]) {
    notificationCoordinator.scheduleGravityOutcomeNotifications(outcomes) { [serverLabel] id in
      serverLabel(id)
    }
  }
}
