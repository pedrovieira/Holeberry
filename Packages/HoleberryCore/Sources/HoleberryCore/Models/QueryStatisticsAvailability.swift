import Foundation

/// Availability of the latest query-summary batch, derived only from query-summary reads.
/// Blocking state is deliberately excluded.
public enum QueryStatisticsAvailability: Equatable, Sendable {
  /// No fetch has completed yet, or no servers are configured.
  case notChecked
  /// Every configured server returned a query summary.
  case allAvailable
  /// At least one, but not every, configured server returned a query summary.
  case someAvailable
  /// No configured server returned a query summary.
  case noneAvailable
}
