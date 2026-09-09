import Defaults
import Foundation

/// The fixed cadence options for automatic gravity updates. Order matters:
/// `allCases` drives the Settings picker — "Never" is last (ascending
/// intervals ending in the off-state).
public enum GravityUpdateCadence: String, Codable, Defaults.Serializable, CaseIterable {
  case every6Hours
  case every12Hours
  case daily
  case weekly
  case never
}

extension GravityUpdateCadence {
  /// `nil` is the off-state; `.daily`/`.weekly` roll from the last run,
  /// not from a wall-clock time of day.
  public var intervalSeconds: TimeInterval? {
    switch self {
    case .every6Hours: return .hours(6)
    case .every12Hours: return .hours(12)
    case .daily: return .days(1)
    case .weekly: return .days(7)
    case .never: return nil
    }
  }
}
