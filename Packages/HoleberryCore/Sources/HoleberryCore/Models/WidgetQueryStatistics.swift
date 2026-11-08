import Foundation

/// Stable identity of one configured Pi-hole server for widget statistics.
///
/// `ServerConfig` equality compares only `id`, so this type includes the URL and
/// API version as well. Changing either invalidates a fetch collected for the
/// previous endpoint.
public struct WidgetServerIdentity: Equatable, Sendable {
  public let id: UUID
  public let url: String
  public let version: ServerVersion

  public init(id: UUID, url: String, version: ServerVersion) {
    self.id = id
    self.url = url
    self.version = version
  }

  public init(server: ServerConfig) {
    self.init(id: server.id, url: server.url, version: server.version)
  }
}

/// Query counts and blocked percentage from one successful widget fetch.
///
/// The totals cover every server in the selected scope at `observedAt`.
/// Partial results never produce an observation.
public struct WidgetQueryStatistics: Equatable, Sendable {
  public let totalQueries: Int
  public let totalBlocked: Int
  public let observedAt: Date

  public init(totalQueries: Int, totalBlocked: Int, observedAt: Date) {
    self.totalQueries = totalQueries
    self.totalBlocked = totalBlocked
    self.observedAt = observedAt
  }

  /// Creates an observation only when every supplied server has a successful summary.
  public init?(
    servers: [WidgetServerIdentity],
    results: [UUID: Result<QuerySummary, PiholeError>],
    observedAt: Date
  ) {
    guard !servers.isEmpty, Set(servers.map(\.id)).count == servers.count else { return nil }

    var totalQueries = 0
    var totalBlocked = 0
    for server in servers {
      guard case .success(let summary)? = results[server.id] else { return nil }
      totalQueries += summary.totalQueries
      totalBlocked += summary.totalBlocked
    }

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
