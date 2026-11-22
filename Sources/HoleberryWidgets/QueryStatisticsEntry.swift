import Foundation
import HoleberryCore
import WidgetKit

/// The existing all-servers widget entry.
///
/// It stores only the WidgetKit render date and the shared query snapshot; the
/// counts, availability, last-check time, display state, and status text come
/// from ``ServerWidgetEntry`` defaults.
struct QueryStatisticsEntry: ServerWidgetEntry {
  let date: Date
  let base: QueryStatisticsSnapshot

  static func placeholder(
    now: Date = Date(),
    scope: ServerScope = .all,
    serverName: String? = nil
  ) -> QueryStatisticsEntry {
    let server = ServerConfig(
      id: placeholderServerID(for: scope),
      label: serverName,
      url: "https://example.invalid",
      version: .v6
    )
    let observations = ServerQueryObservation.make(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 184_200, totalBlocked: 31_200))],
      checkedAt: now
    )
    return QueryStatisticsEntry(
      date: now,
      base: QueryStatisticsSnapshot(
        scope: scope,
        setupRequired: false,
        observations: observations
      )
    )
  }

  static func setupRequired(now: Date = Date(), scope: ServerScope = .all) -> QueryStatisticsEntry {
    QueryStatisticsEntry(
      date: now,
      base: QueryStatisticsSnapshot(scope: scope, setupRequired: true, observations: [])
    )
  }

  /// An entry with no observations: no saved servers, or a removed selection.
  static func empty(now: Date = Date(), scope: ServerScope = .all) -> QueryStatisticsEntry {
    QueryStatisticsEntry(
      date: now,
      base: QueryStatisticsSnapshot(scope: scope, setupRequired: false, observations: [])
    )
  }

  /// A scoped placeholder must carry a matching server identifier, or snapshot
  /// normalization would filter its sample server away.
  private static func placeholderServerID(for scope: ServerScope) -> UUID {
    switch scope {
    case .all: return UUID()
    case .server(let id): return id
    }
  }
}
