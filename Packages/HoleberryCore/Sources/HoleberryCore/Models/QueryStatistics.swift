import Foundation

/// Query counts and blocked percentage from one statistics fetch.
///
/// The totals cover servers that returned a successful summary in the selected
/// scope at `observedAt`. Failed and missing results are excluded.
public struct QueryStatistics: Equatable, Sendable {
  public let totalQueries: Int
  public let totalBlocked: Int
  public let observedAt: Date

  public init(totalQueries: Int, totalBlocked: Int, observedAt: Date) {
    self.totalQueries = totalQueries
    self.totalBlocked = totalBlocked
    self.observedAt = observedAt
  }

  /// Creates an observation when at least one supplied server has a successful summary.
  ///
  /// Duplicate identifiers describe the same server and count once, using the
  /// first occurrence. Returns nil when a total would overflow, so malformed or
  /// future range changes never trap.
  public init?(
    servers: [ServerConfig],
    results: [UUID: Result<QuerySummary, PiholeError>],
    observedAt: Date
  ) {
    guard !servers.isEmpty else { return nil }

    var seenServerIDs: Set<UUID> = []
    var totalQueries = 0
    var totalBlocked = 0
    var successCount = 0
    for server in servers {
      guard seenServerIDs.insert(server.id).inserted else { continue }
      guard case .success(let summary)? = results[server.id] else { continue }
      let (queries, queriesOverflowed) = totalQueries.addingReportingOverflow(summary.totalQueries)
      let (blocked, blockedOverflowed) = totalBlocked.addingReportingOverflow(summary.totalBlocked)
      guard !queriesOverflowed, !blockedOverflowed else { return nil }
      successCount += 1
      totalQueries = queries
      totalBlocked = blocked
    }

    guard successCount > 0 else { return nil }

    self.init(
      totalQueries: totalQueries,
      totalBlocked: totalBlocked,
      observedAt: observedAt
    )
  }

  /// Weighted aggregate percentage. Zero queries safely produce zero.
  public var blockedPercentage: Double {
    guard totalQueries > 0 else { return 0 }
    return 100 * Double(totalBlocked) / Double(totalQueries)
  }
}
