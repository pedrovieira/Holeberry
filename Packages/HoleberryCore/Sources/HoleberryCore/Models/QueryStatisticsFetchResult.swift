import Foundation

/// Availability of the latest statistics fetch, derived only from query-summary reads.
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

/// Transient result of one live query statistics fetch.
///
/// Statistics include the configured servers that returned a query summary for
/// this fetch. No aggregate is persisted or reused across fetches.
public struct QueryStatisticsFetchResult: Sendable {
  public let servers: [QueryStatisticsServer]
  public let results: [UUID: Result<QuerySummary, PiholeError>]
  public let checkedAt: Date?

  public init(
    servers: [QueryStatisticsServer],
    results: [UUID: Result<QuerySummary, PiholeError>],
    checkedAt: Date?
  ) {
    self.servers = servers
    self.results = results
    self.checkedAt = checkedAt
  }

  /// Availability of the latest attempt. An empty configuration is always not checked.
  public var availability: QueryStatisticsAvailability {
    guard !servers.isEmpty, checkedAt != nil else { return .notChecked }

    var successCount = 0
    for server in servers {
      if case .success = results[server.id] {
        successCount += 1
      }
    }

    if successCount == servers.count { return .allAvailable }
    if successCount == 0 { return .noneAvailable }
    return .someAvailable
  }

  /// A new observation from the servers that succeeded in the latest attempt.
  public var completedStatistics: QueryStatistics? {
    guard let checkedAt else { return nil }
    return QueryStatistics(servers: servers, results: results, observedAt: checkedAt)
  }
}
