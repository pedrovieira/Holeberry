import HoleberryCore

extension GravityUpdateCadence {
  /// User-facing picker copy; keep in sync with the design spec.
  var displayName: String {
    switch self {
    case .every6Hours: return "Every 6 hours"
    case .every12Hours: return "Every 12 hours"
    case .daily: return "Daily"
    case .weekly: return "Weekly"
    case .never: return "Never"
    }
  }
}
