import Foundation
import HoleberryCore
import SwiftUI

// Xcode cannot host previews in a macOS widget extension: it launches the
// `widgetExtension` process type, which macOS does not support
// ("No plugin is registered to launch the process type widgetExtension").
// Keep the view compiled into the app target and preview it here instead.
// Every preview is sized to the macOS systemSmall widget via
// `WidgetPreviewSize.systemSmall`.
#Preview("Healthy") {
  AllServersWidgetEntryView(entry: .placeholder())
    .widgetPreviewFrame(.systemSmall)
}

#Preview("Partial") {
  AllServersWidgetEntryView(entry: WidgetPreviewData.partial())
    .widgetPreviewFrame(.systemSmall)
}

#Preview("All offline") {
  AllServersWidgetEntryView(entry: WidgetPreviewData.allOffline())
    .widgetPreviewFrame(.systemSmall)
}

#Preview("No servers") {
  AllServersWidgetEntryView(entry: WidgetPreviewData.noServers())
    .widgetPreviewFrame(.systemSmall)
}

#Preview("Setup required") {
  AllServersWidgetEntryView(entry: .setupRequired())
    .widgetPreviewFrame(.systemSmall)
}

#Preview("Zero") {
  AllServersWidgetEntryView(entry: WidgetPreviewData.zero())
    .widgetPreviewFrame(.systemSmall)
}

#Preview("Stale") {
  AllServersWidgetEntryView(entry: WidgetPreviewData.stale())
    .widgetPreviewFrame(.systemSmall)
}

private enum WidgetPreviewData {
  static func partial(now: Date = .now) -> QueryStatisticsEntry {
    let first = ServerConfig(id: UUID(), url: "https://first.example", version: .v6)
    let second = ServerConfig(id: UUID(), url: "https://second.example", version: .v6)
    return QueryStatisticsEntry(
      date: now,
      setupRequired: false,
      summary: QueryStatisticsFetchResult(
        servers: [first, second],
        results: [
          first.id: .success(QuerySummary(totalQueries: 100, totalBlocked: 10)),
          second.id: .failure(.network("preview"))
        ],
        checkedAt: now
      )
    )
  }

  static func allOffline(now: Date = .now) -> QueryStatisticsEntry {
    let first = ServerConfig(id: UUID(), url: "https://first.example", version: .v6)
    let second = ServerConfig(id: UUID(), url: "https://second.example", version: .v6)
    return QueryStatisticsEntry(
      date: now,
      setupRequired: false,
      summary: QueryStatisticsFetchResult(
        servers: [first, second],
        results: [
          first.id: .failure(.network("preview")),
          second.id: .failure(.network("preview"))
        ],
        checkedAt: now
      )
    )
  }

  static func noServers(now: Date = .now) -> QueryStatisticsEntry {
    QueryStatisticsEntry(
      date: now,
      setupRequired: false,
      summary: QueryStatisticsFetchResult(servers: [], results: [:], checkedAt: now)
    )
  }

  static func zero(now: Date = .now) -> QueryStatisticsEntry {
    let server = ServerConfig(id: UUID(), url: "https://zero.example", version: .v6)
    return QueryStatisticsEntry(
      date: now,
      setupRequired: false,
      summary: QueryStatisticsFetchResult(
        servers: [server],
        results: [server.id: .success(QuerySummary(totalQueries: 0, totalBlocked: 0))],
        checkedAt: now
      )
    )
  }

  static func stale(now: Date = .now) -> QueryStatisticsEntry {
    let server = ServerConfig(id: UUID(), url: "https://stale.example", version: .v6)
    let observedAt = now.addingTimeInterval(-2 * 60 * 60)
    return QueryStatisticsEntry(
      date: now,
      setupRequired: false,
      summary: QueryStatisticsFetchResult(
        servers: [server],
        results: [
          server.id: .success(QuerySummary(totalQueries: 50_000, totalBlocked: 5_000))
        ],
        checkedAt: observedAt
      )
    )
  }
}
