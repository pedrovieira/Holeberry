import Foundation

/// Display state of the "Update Gravity" menu section.
enum GravityMenuState {
  /// The section is hidden (user disabled it in settings).
  case hidden
  /// No configured instance can trigger a gravity update via its API (e.g.
  /// only Pi-hole v5 instances); show a disabled "last updated" row instead.
  case noUpdateCapableInstances
  /// A gravity update is in flight; show a spinner row.
  case updating
  /// Ready to trigger an update; carries app-observed completion timestamps.
  case ready(completedAt: [UUID: Date])
}
