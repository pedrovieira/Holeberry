import Foundation
import HoleberryCore
import WidgetKit

/// Query-summary display data for the date WidgetKit renders this entry.
struct QueryStatisticsEntry: TimelineEntry, Sendable {
  let date: Date
  let setupRequired: Bool
  let summary: WidgetSummary?

  var presentation: WidgetPresentation {
    guard !setupRequired, let summary else { return .setupRequired }
    return WidgetPresentation(summary: summary, now: date)
  }

  static func placeholder(now: Date = Date()) -> QueryStatisticsEntry {
    let server = WidgetServerIdentity(
      id: UUID(),
      url: "https://example.invalid",
      version: .v6
    )
    let summary = WidgetSummary(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 12_345, totalBlocked: 3_210))],
      checkedAt: now
    )
    return QueryStatisticsEntry(date: now, setupRequired: false, summary: summary)
  }

  static func setupRequired(now: Date = Date()) -> QueryStatisticsEntry {
    QueryStatisticsEntry(date: now, setupRequired: true, summary: nil)
  }
}
