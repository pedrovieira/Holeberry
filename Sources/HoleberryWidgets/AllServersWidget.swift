import AppKit
import HoleberryCore
import SwiftUI
import WidgetKit

struct AllServersWidgetEntryView: View {
  let entry: QueryStatisticsEntry

  private let pink = Color.pink
  private let amber = Color(red: 1, green: 0.624, blue: 0.039)

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      header
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .padding(2)
    .containerBackground(for: .widget) {
      Color(nsColor: .windowBackgroundColor)
    }
    .widgetURL(URL(string: "holeberry://settings"))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
  }

  private var header: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(healthColor)
        .frame(width: 8, height: 8)
      Text("All servers")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.primary)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch entry.presentation.content {
    case .setupRequired:
      guidance("Open Holeberry to finish setup")
    case .noServers:
      guidance("Add a server in Holeberry")
    case .unavailable:
      Spacer(minLength: 0)
      Text("Statistics unavailable")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    case .statistics(let statistics):
      percentage(statistics)
      bar(statistics)
      counts(statistics)
      Spacer(minLength: 0)
      footer(statistics)
    }
  }

  private func percentage(_ statistics: WidgetQueryStatistics) -> some View {
    VStack(alignment: .leading, spacing: -2) {
      Text(statistics.blockedPercentage / 100, format: .percent.precision(.fractionLength(1)))
        .font(.system(size: 40, weight: .bold, design: .rounded))
        .foregroundStyle(pink)
        .minimumScaleFactor(0.6)
        .lineLimit(1)
      Text("blocked")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private func bar(_ statistics: WidgetQueryStatistics) -> some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(pink.opacity(0.18))
        Capsule()
          .fill(pink)
          .frame(width: geometry.size.width * statistics.blockedFraction)
      }
    }
    .frame(height: 5)
  }

  private func counts(_ statistics: WidgetQueryStatistics) -> some View {
    Text(
      "\(statistics.totalBlocked, format: .number) blocked of \(statistics.totalQueries, format: .number)"
    )
    .font(.caption2)
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .minimumScaleFactor(0.7)
  }

  private func footer(_ statistics: WidgetQueryStatistics) -> some View {
    Text("Updated \(statistics.observedAt, format: .dateTime.hour().minute())")
      .font(.caption2)
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }

  private func guidance(_ text: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Spacer(minLength: 0)
      Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }

  private var healthColor: Color {
    switch entry.presentation.health {
    case .allHealthy: return .green
    case .someHealthy: return amber
    case .noneHealthy: return .red
    case .notChecked: return .gray
    }
  }

  private var accessibilityText: String {
    let healthText: String
    switch entry.presentation.health {
    case .allHealthy: healthText = "All servers healthy"
    case .someHealthy: healthText = "Some servers healthy"
    case .noneHealthy: healthText = "No servers healthy"
    case .notChecked: healthText = "Health not checked"
    }

    var parts = ["All servers", healthText]
    if let statistics = entry.presentation.statistics {
      let percentage = statistics.blockedPercentage.formatted(
        .number.precision(.fractionLength(1))
      )
      parts.append("\(percentage) percent blocked")
      parts.append("\(statistics.totalBlocked) blocked of \(statistics.totalQueries) queries")
      parts.append("Updated \(statistics.observedAt.formatted(date: .omitted, time: .shortened))")
    } else {
      switch entry.presentation.content {
      case .setupRequired:
        parts.append("Open Holeberry to finish setup")
      case .noServers:
        parts.append("Add a server in Holeberry")
      case .unavailable:
        parts.append("Statistics unavailable")
      case .statistics:
        break
      }
    }
    return parts.joined(separator: ". ")
  }
}

struct AllServersWidget: Widget {
  let kind = "AllServersWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: QueryStatisticsProvider(scope: .all)) { entry in
      AllServersWidgetEntryView(entry: entry)
    }
    .configurationDisplayName("All servers")
    .description("Blocked percentage and query totals for all Pi-hole servers.")
    .supportedFamilies([.systemSmall])
  }
}

#Preview(as: .systemSmall) {
  AllServersWidget()
} timeline: {
  QueryStatisticsEntry.placeholder()
}
