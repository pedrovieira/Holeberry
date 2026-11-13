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
  public init?(
    servers: [QueryStatisticsServer],
    results: [UUID: Result<QuerySummary, PiholeError>],
    observedAt: Date
  ) {
    guard !servers.isEmpty, Set(servers.map(\.id)).count == servers.count else { return nil }

    var totalQueries = 0
    var totalBlocked = 0
    var successCount = 0
    for server in servers {
      guard case .success(let summary)? = results[server.id] else { continue }
      successCount += 1
      totalQueries += summary.totalQueries
      totalBlocked += summary.totalBlocked
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

  /// Clamped fraction for rendering the proportional bar.
  public var blockedFraction: Double {
    min(max(blockedPercentage / 100, 0), 1)
  }
}
