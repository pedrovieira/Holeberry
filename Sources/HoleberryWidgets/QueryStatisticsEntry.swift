import Foundation
import HoleberryCore
import WidgetKit

/// Query-summary display data for the date WidgetKit renders this entry.
struct QueryStatisticsEntry: TimelineEntry, Sendable {
  let date: Date
  let setupRequired: Bool
  let summary: QueryStatisticsFetchResult?

  var presentation: WidgetPresentation {
    guard !setupRequired, let summary else { return .setupRequired }
    return WidgetPresentation(summary: summary, now: date)
  }

  static func placeholder(now: Date = Date()) -> QueryStatisticsEntry {
    let server = ServerConfig(
      id: UUID(),
      url: "https://example.invalid",
      version: .v6
    )
    let summary = QueryStatisticsFetchResult(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 184_200, totalBlocked: 31_200))],
      checkedAt: now
    )
    return QueryStatisticsEntry(date: now, setupRequired: false, summary: summary)
  }

  static func setupRequired(now: Date = Date()) -> QueryStatisticsEntry {
    QueryStatisticsEntry(date: now, setupRequired: true, summary: nil)
  }
}
