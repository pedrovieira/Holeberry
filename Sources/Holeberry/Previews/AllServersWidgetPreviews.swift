import Foundation
import HoleberryCore
import SwiftUI

// Xcode cannot host previews in a macOS widget extension: it launches the
// `widgetExtension` process type, which macOS does not support
// ("No plugin is registered to launch the process type widgetExtension").
// Keep the view compiled into the app target and preview it here instead.
// Sized to the macOS systemSmall widget (170 x 170 points).
#Preview("Healthy") {
  AllServersWidgetEntryView(entry: .placeholder())
    .frame(width: 170, height: 170)
}

#Preview("Partial") {
  AllServersWidgetEntryView(entry: WidgetPreviewData.partial())
    .frame(width: 170, height: 170)
}

#Preview("All offline") {
  AllServersWidgetEntryView(entry: WidgetPreviewData.allOffline())
    .frame(width: 170, height: 170)
}

#Preview("No servers") {
  AllServersWidgetEntryView(entry: WidgetPreviewData.noServers())
    .frame(width: 170, height: 170)
}

#Preview("Setup required") {
  AllServersWidgetEntryView(entry: .setupRequired())
    .frame(width: 170, height: 170)
}

#Preview("Zero") {
  AllServersWidgetEntryView(entry: WidgetPreviewData.zero())
    .frame(width: 170, height: 170)
}

#Preview("Stale") {
  AllServersWidgetEntryView(entry: WidgetPreviewData.stale())
    .frame(width: 170, height: 170)
}

private enum WidgetPreviewData {
  static func partial(now: Date = .now) -> QueryStatisticsEntry {
    let first = WidgetServerIdentity(id: UUID(), url: "https://first.example", version: .v6)
    let second = WidgetServerIdentity(id: UUID(), url: "https://second.example", version: .v6)
    return QueryStatisticsEntry(
      date: now,
      setupRequired: false,
      summary: WidgetSummary(
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
    let first = WidgetServerIdentity(id: UUID(), url: "https://first.example", version: .v6)
    let second = WidgetServerIdentity(id: UUID(), url: "https://second.example", version: .v6)
    return QueryStatisticsEntry(
      date: now,
      setupRequired: false,
      summary: WidgetSummary(
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
      summary: WidgetSummary(servers: [], results: [:], checkedAt: now)
    )
  }

  static func zero(now: Date = .now) -> QueryStatisticsEntry {
    let server = WidgetServerIdentity(id: UUID(), url: "https://zero.example", version: .v6)
    return QueryStatisticsEntry(
      date: now,
      setupRequired: false,
      summary: WidgetSummary(
        servers: [server],
        results: [server.id: .success(QuerySummary(totalQueries: 0, totalBlocked: 0))],
        checkedAt: now
      )
    )
  }

  static func stale(now: Date = .now) -> QueryStatisticsEntry {
    let server = WidgetServerIdentity(id: UUID(), url: "https://stale.example", version: .v6)
    let observedAt = now.addingTimeInterval(-2 * 60 * 60)
    return QueryStatisticsEntry(
      date: now,
      setupRequired: false,
      summary: WidgetSummary(
        servers: [server],
        results: [
          server.id: .success(QuerySummary(totalQueries: 50_000, totalBlocked: 5_000))
        ],
        checkedAt: observedAt
      )
    )
  }
}
