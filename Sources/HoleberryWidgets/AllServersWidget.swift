import AppKit
import Foundation
import HoleberryCore
import SwiftUI
import WidgetKit

struct AllServersWidgetEntryView: View {
  let entry: QueryStatisticsEntry

  private static let nominalCardSide: CGFloat = 160
  private static let contentInset: CGFloat = 17
  private static let bottomInset: CGFloat = 13
  private static let dividerSpacing: CGFloat = 5
  private static let middleGap: CGFloat = 8
  private static let blockedBlue = Color(
    .sRGB,
    red: 108.0 / 255.0,
    green: 182.0 / 255.0,
    blue: 255.0 / 255.0
  )

  var body: some View {
    GeometryReader { proxy in
      let scale = max(proxy.size.width / Self.nominalCardSide, 0.1)
      content(scale: scale)
        .padding(.horizontal, Self.contentInset * scale)
        .padding(.top, Self.contentInset * scale)
        .padding(.bottom, Self.bottomInset * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .containerBackground(for: .widget) {
      Color(nsColor: .windowBackgroundColor)
    }
    .widgetURL(URL(string: "holeberry://settings"))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
  }

  @ViewBuilder
  private func content(scale: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      header(scale: scale)
      switch entry.presentation.content {
      case .statistics(let statistics):
        statisticsContent(statistics, scale: scale)
      case .setupRequired:
        guidance("Open Holeberry to finish setup", scale: scale)
      case .noServers:
        guidance("Add a server in Holeberry", scale: scale)
      case .unavailable:
        guidance("Statistics unavailable", scale: scale)
      }
    }
  }

  private func header(scale: CGFloat) -> some View {
    HStack(alignment: .center, spacing: 4 * scale) {
      Circle()
        .fill(healthColor)
        .frame(width: 10 * scale, height: 10 * scale)
      Text(statusText)
        .font(.system(size: 9.5 * scale, weight: .semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
      Spacer(minLength: 4 * scale)
      Text("24h")
        .font(.system(size: 9 * scale, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(height: 12 * scale)
  }

  @ViewBuilder
  private func statisticsContent(_ statistics: WidgetQueryStatistics, scale: CGFloat) -> some View {
    hero(statistics, scale: scale)
    Text("block rate")
      .font(.system(size: 10 * scale, weight: .semibold))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .padding(.top, -1 * scale)
    horizontalSeparator(scale: scale)
      .padding(.top, Self.dividerSpacing * scale)
    metrics(statistics, scale: scale)
      .padding(.top, Self.dividerSpacing * scale)
    Spacer(minLength: 6 * scale)
    footer(statistics, scale: scale)
  }

  private func hero(_ statistics: WidgetQueryStatistics, scale: CGFloat) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      Text(statistics.blockedPercentage, format: .number.precision(.fractionLength(1)))
        .font(.system(size: 42 * scale, weight: .bold))
        .foregroundStyle(.primary)
        .tracking(-1 * scale)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
      Text(verbatim: "%")
        .font(.system(size: 21 * scale, weight: .bold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }

  private func metrics(_ statistics: WidgetQueryStatistics, scale: CGFloat) -> some View {
    HStack(alignment: .center, spacing: 0) {
      metricColumn(
        value: statistics.totalQueries,
        caption: "Queries",
        color: .primary,
        scale: scale
      )
      .frame(maxWidth: .infinity, alignment: .leading)

      Rectangle()
        .fill(Color(nsColor: .separatorColor))
        .frame(width: 0.5 * scale, height: 20 * scale)

      metricColumn(
        value: statistics.totalBlocked,
        caption: "Blocked",
        color: Self.blockedBlue,
        scale: scale
      )
      .padding(.leading, Self.middleGap * scale)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func metricColumn(
    value: Int,
    caption: String,
    color: Color,
    scale: CGFloat
  ) -> some View {
    VStack(alignment: .leading, spacing: 1 * scale) {
      Text(value, format: .number.notation(.compactName).precision(.fractionLength(0...1)))
        .font(.system(size: 13.5 * scale, weight: .bold))
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      Text(caption)
        .font(.system(size: 10 * scale, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }

  private func horizontalSeparator(scale: CGFloat) -> some View {
    Rectangle()
      .fill(Color(nsColor: .separatorColor))
      .frame(maxWidth: .infinity)
      .frame(height: 0.5 * scale)
  }

  private func footer(_ statistics: WidgetQueryStatistics, scale: CGFloat) -> some View {
    let age = RelativeAgeFormatter(style: .compact).string(
      since: statistics.observedAt,
      relativeTo: entry.date
    )
    return Text(verbatim: "Updated \(age)")
      .font(.system(size: 9 * scale, weight: .medium))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .multilineTextAlignment(.leading)
  }

  private func guidance(_ text: String, scale: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Spacer(minLength: 8 * scale)
      Text(text)
        .font(.system(size: 10 * scale, weight: .medium))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }

  private static func updatedText(for date: Date) -> String {
    let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
    return String(format: "Updated %02dh%02d", components.hour ?? 0, components.minute ?? 0)
  }

  private var statusText: String {
    switch entry.presentation.health {
    case .allHealthy: return "All servers online"
    case .someHealthy: return "Some servers offline"
    case .noneHealthy: return "All servers offline"
    case .notChecked: return "All servers"
    }
  }

  private var healthColor: Color {
    switch entry.presentation.health {
    case .allHealthy: return .green
    case .someHealthy: return Color(red: 1, green: 0.624, blue: 0.039)
    case .noneHealthy: return .red
    case .notChecked: return .gray
    }
  }

  private var healthGlyph: String {
    switch entry.presentation.health {
    case .allHealthy: return "checkmark"
    case .someHealthy: return "exclamationmark"
    case .noneHealthy: return "xmark"
    case .notChecked: return "questionmark"
    }
  }

  private var healthGlyphColor: Color {
    switch entry.presentation.health {
    case .allHealthy, .someHealthy: return .black.opacity(0.75)
    case .noneHealthy, .notChecked: return .white
    }
  }

  private var accessibilityText: String {
    var parts = [statusText, "24 hours"]
    if let statistics = entry.presentation.statistics {
      let percentage = statistics.blockedPercentage.formatted(
        .number.precision(.fractionLength(1))
      )
      parts.append("\(percentage) percent block rate")
      parts.append("\(statistics.totalQueries.formatted(.number)) queries")
      parts.append("\(statistics.totalBlocked.formatted(.number)) blocked")
      parts.append(Self.updatedText(for: statistics.observedAt))
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
    .description("Block rate and query totals for all Pi-hole servers.")
    .supportedFamilies([.systemSmall])
    .contentMarginsDisabled()
  }
}

#Preview(as: .systemSmall) {
  AllServersWidget()
} timeline: {
  QueryStatisticsEntry.placeholder()
}

#Preview("Partial", as: .systemSmall) {
  AllServersWidget()
} timeline: {
  WidgetPreviewData.partial()
}

#Preview("Zero", as: .systemSmall) {
  AllServersWidget()
} timeline: {
  WidgetPreviewData.zero()
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
}
