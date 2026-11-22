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
  ServerStatisticsGlanceWidgetEntryView(entry: .placeholder())
    .widgetPreviewFrame(.systemSmall)
}

#Preview("Healthy · Light") {
  ServerStatisticsGlanceWidgetEntryView(entry: .placeholder())
    .widgetPreviewFrame(.systemSmall)
    .preferredColorScheme(.light)
}

#Preview("Healthy · Dark") {
  ServerStatisticsGlanceWidgetEntryView(entry: .placeholder())
    .widgetPreviewFrame(.systemSmall)
    .preferredColorScheme(.dark)
}

#Preview("Partial") {
  ServerStatisticsGlanceWidgetEntryView(entry: WidgetPreviewData.partial())
    .widgetPreviewFrame(.systemSmall)
}

#Preview("All offline") {
  ServerStatisticsGlanceWidgetEntryView(entry: WidgetPreviewData.allOffline())
    .widgetPreviewFrame(.systemSmall)
}

#Preview("No servers") {
  ServerStatisticsGlanceWidgetEntryView(entry: WidgetPreviewData.noServers())
    .widgetPreviewFrame(.systemSmall)
}

#Preview("Setup required") {
  ServerStatisticsGlanceWidgetEntryView(entry: .setupRequired())
    .widgetPreviewFrame(.systemSmall)
}

#Preview("Zero") {
  ServerStatisticsGlanceWidgetEntryView(entry: WidgetPreviewData.zero())
    .widgetPreviewFrame(.systemSmall)
}

#Preview("Stale") {
  ServerStatisticsGlanceWidgetEntryView(entry: WidgetPreviewData.stale())
    .widgetPreviewFrame(.systemSmall)
}

#Preview("One server") {
  ServerStatisticsGlanceWidgetEntryView(entry: WidgetPreviewData.individual())
    .widgetPreviewFrame(.systemSmall)
}

#Preview("One server - Long name") {
  ServerStatisticsGlanceWidgetEntryView(entry: WidgetPreviewData.individualLongName())
    .widgetPreviewFrame(.systemSmall)
}

#Preview("One server - Unavailable") {
  ServerStatisticsGlanceWidgetEntryView(entry: WidgetPreviewData.individualUnavailable())
    .widgetPreviewFrame(.systemSmall)
}

#Preview("One server - Server removed") {
  ServerStatisticsGlanceWidgetEntryView(entry: WidgetPreviewData.removedServer())
    .widgetPreviewFrame(.systemSmall)
}

private enum WidgetPreviewData {
  static func partial(now: Date = .now) -> QueryStatisticsEntry {
    let first = ServerConfig(id: UUID(), url: "https://first.example", version: .v6)
    let second = ServerConfig(id: UUID(), url: "https://second.example", version: .v6)
    return entry(
      now: now,
      servers: [first, second],
      results: [
        first.id: .success(QuerySummary(totalQueries: 100, totalBlocked: 10)),
        second.id: .failure(.network("preview"))
      ]
    )
  }

  static func allOffline(now: Date = .now) -> QueryStatisticsEntry {
    let first = ServerConfig(id: UUID(), url: "https://first.example", version: .v6)
    let second = ServerConfig(id: UUID(), url: "https://second.example", version: .v6)
    return entry(
      now: now,
      servers: [first, second],
      results: [
        first.id: .failure(.network("preview")),
        second.id: .failure(.network("preview"))
      ]
    )
  }

  static func noServers(now: Date = .now) -> QueryStatisticsEntry {
    QueryStatisticsEntry(
      date: now,
      base: QueryStatisticsSnapshot(scope: .all, setupRequired: false, observations: [])
    )
  }

  static func zero(now: Date = .now) -> QueryStatisticsEntry {
    let server = ServerConfig(id: UUID(), url: "https://zero.example", version: .v6)
    return entry(
      now: now,
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 0, totalBlocked: 0))]
    )
  }

  static func stale(now: Date = .now) -> QueryStatisticsEntry {
    let server = ServerConfig(id: UUID(), url: "https://stale.example", version: .v6)
    return entry(
      now: now,
      checkedAt: now.addingTimeInterval(-2 * 60 * 60),
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 50_000, totalBlocked: 5_000))]
    )
  }

  static func individual(now: Date = .now) -> QueryStatisticsEntry {
    let server = ServerConfig(label: "Home Pi-hole", url: "https://pihole.example", version: .v6)
    return entry(
      now: now,
      scope: .server(server.id),
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 84_000, totalBlocked: 21_000))]
    )
  }

  static func individualLongName(now: Date = .now) -> QueryStatisticsEntry {
    let server = ServerConfig(
      label: "Downstairs living room Pi-hole",
      url: "https://pihole.example",
      version: .v6
    )
    return entry(
      now: now,
      scope: .server(server.id),
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 84_000, totalBlocked: 21_000))]
    )
  }

  static func individualUnavailable(now: Date = .now) -> QueryStatisticsEntry {
    let server = ServerConfig(label: "Home Pi-hole", url: "https://pihole.example", version: .v6)
    return entry(
      now: now,
      scope: .server(server.id),
      servers: [server],
      results: [server.id: .failure(.network("preview"))]
    )
  }

  static func removedServer(now: Date = .now) -> QueryStatisticsEntry {
    QueryStatisticsEntry(
      date: now,
      base: QueryStatisticsSnapshot(scope: .server(UUID()), setupRequired: false, observations: [])
    )
  }

  private static func entry(
    now: Date,
    checkedAt: Date? = nil,
    scope: ServerScope = .all,
    servers: [ServerConfig],
    results: [UUID: Result<QuerySummary, PiholeError>]
  ) -> QueryStatisticsEntry {
    QueryStatisticsEntry(
      date: now,
      base: QueryStatisticsSnapshot(
        scope: scope,
        setupRequired: false,
        observations: ServerQueryObservation.make(
          servers: servers,
          results: results,
          checkedAt: checkedAt ?? now
        )
      )
    )
  }
}
