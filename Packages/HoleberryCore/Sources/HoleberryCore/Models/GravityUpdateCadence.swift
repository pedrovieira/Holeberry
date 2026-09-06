import Defaults
import Foundation

/// The fixed cadence options for automatic gravity updates.
///
/// Order matters: `CaseIterable`'s synthesized `allCases` follows declaration
/// order, and the Settings picker is built from `allCases` — this order IS
/// the menu order. "Never" is last deliberately (ascending intervals ending
/// in the off-state, mirroring Apple's interval popups).
public enum GravityUpdateCadence: String, Codable, Defaults.Serializable, CaseIterable {
  case every6Hours
  case every12Hours
  case daily
  case weekly
  case never
}

extension GravityUpdateCadence {
  /// `nil` means "don't schedule anything" — the off-state.
  /// `.daily` and `.weekly` are rolling intervals from the last run, not
  /// anchored to a wall-clock time of day.
  public var intervalSeconds: TimeInterval? {
    switch self {
    case .every6Hours: return 6 * 3600
    case .every12Hours: return 12 * 3600
    case .daily: return 24 * 3600
    case .weekly: return 7 * 24 * 3600
    case .never: return nil
    }
  }

  /// Exact menu copy. Keep in sync with the design spec if either changes.
  public var menuTitle: String {
    switch self {
    case .every6Hours: return "Every 6 hours"
    case .every12Hours: return "Every 12 hours"
    case .daily: return "Daily"
    case .weekly: return "Weekly"
    case .never: return "Never"
    }
  }
}
