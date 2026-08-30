import Foundation

/// Display state of the "Update Gravity" menu section.
enum GravityMenuState {
  /// The section is hidden (user disabled it in settings).
  case hidden
  /// A gravity update is in flight; show a spinner row.
  case updating
  /// Ready to trigger an update; carries app-observed completion timestamps.
  case ready(completedAt: [UUID: Date])
}
