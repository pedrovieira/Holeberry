import Foundation

/// Health of the latest widget fetch, derived only from query-summary reads.
/// Blocking state is deliberately excluded.
public enum WidgetHealth: Equatable, Sendable {
  /// No fetch has completed yet, or no servers are configured.
  case notChecked
  /// Every configured server returned a query summary.
  case allHealthy
  /// At least one, but not every, configured server returned a query summary.
  case someHealthy
  /// No configured server returned a query summary.
  case noneHealthy
}

/// Transient result of one live widget fetch.
///
/// Statistics are produced only when every configured server returned a query
/// summary for this fetch. No aggregate is persisted or reused across fetches.
public struct WidgetSummary: Sendable {
  public let servers: [WidgetServerIdentity]
  public let results: [UUID: Result<QuerySummary, PiholeError>]
  public let checkedAt: Date?

  public init(
    servers: [WidgetServerIdentity],
    results: [UUID: Result<QuerySummary, PiholeError>],
    checkedAt: Date?
  ) {
    self.servers = servers
    self.results = results
    self.checkedAt = checkedAt
  }

  /// Health of the latest attempt. An empty configuration is always not checked.
  public var health: WidgetHealth {
    guard !servers.isEmpty, checkedAt != nil else { return .notChecked }

    var successCount = 0
    for server in servers {
      if case .success = results[server.id] {
        successCount += 1
      }
    }

    if successCount == servers.count { return .allHealthy }
    if successCount == 0 { return .noneHealthy }
    return .someHealthy
  }

  /// A new observation when the latest attempt succeeded for every server.
  public var completedStatistics: WidgetQueryStatistics? {
    guard let checkedAt else { return nil }
    return WidgetQueryStatistics(servers: servers, results: results, observedAt: checkedAt)
  }
}
