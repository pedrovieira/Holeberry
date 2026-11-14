import AppKit
import Foundation
import HoleberryCore
import SwiftUI
import WidgetKit

struct AllServersWidgetEntryView: View {
  let entry: QueryStatisticsEntry

  @Environment(\.colorScheme) private var colorScheme

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
    }
    .containerBackground(for: .widget) {
      Color(nsColor: .windowBackgroundColor)
    }
    .widgetURL(AppDeepLink.settingsURL)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
  }

  @ViewBuilder
  private func content(scale: CGFloat) -> some View {
    switch entry.presentation.content {
    case .statistics(let statistics):
      VStack(alignment: .leading, spacing: 0) {
        header(scale: scale)
        statisticsContent(statistics, scale: scale)
      }
      .padding(.horizontal, Self.contentInset * scale)
      .padding(.top, Self.contentInset * scale)
      .padding(.bottom, Self.bottomInset * scale)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    case .setupRequired:
      guidance("Open Holeberry to finish setup", scale: scale)
    case .noServers:
      guidance("Add a server in Holeberry", scale: scale)
    case .unavailable:
      guidance(unavailableText, scale: scale)
        .overlay(alignment: .topLeading) {
          header(scale: scale)
            .padding(.horizontal, Self.contentInset * scale)
            .padding(.top, Self.contentInset * scale)
        }
    }
  }

  private func header(scale: CGFloat) -> some View {
    HStack(alignment: .center, spacing: 4 * scale) {
      Circle()
        .fill(healthColor)
        .frame(width: 10 * scale, height: 10 * scale)
      if entry.presentation.availability != .noneAvailable {
        Text(statusText)
          .font(.system(size: 8.5 * scale, weight: .semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
      Spacer(minLength: 4 * scale)
      if hasHealthyServer {
        Text("24h")
          .font(.system(size: 9 * scale, weight: .semibold))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .fixedSize()
      }
    }
    .frame(height: 12 * scale)
  }

  @ViewBuilder
  private func statisticsContent(_ statistics: QueryStatistics, scale: CGFloat) -> some View {
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

  private func hero(_ statistics: QueryStatistics, scale: CGFloat) -> some View {
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

  private func metrics(_ statistics: QueryStatistics, scale: CGFloat) -> some View {
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

  private func footer(_ statistics: QueryStatistics, scale: CGFloat) -> some View {
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
    VStack(spacing: 12 * scale) {
      Image("holeberry-logo")
        .resizable()
        .scaledToFit()
        .frame(width: 40 * scale, height: 40 * scale)
        .brightness(colorScheme == .dark ? 0.1 : 0)
        .accessibilityHidden(true)
      Text(text)
        .font(.system(size: 10 * scale, weight: .medium))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, Self.contentInset * scale)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  private static func updatedText(for date: Date) -> String {
    let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
    return String(format: "Updated %02dh%02d", components.hour ?? 0, components.minute ?? 0)
  }

  private var statusText: String {
    switch entry.presentation.availability {
    case .allAvailable: return "All servers online"
    case .someAvailable: return "Some servers offline"
    case .noneAvailable: return "All servers offline"
    case .notChecked: return "All servers"
    }
  }

  private var healthColor: Color {
    switch entry.presentation.availability {
    case .allAvailable: return ServerStatusColor.healthy.color
    case .someAvailable: return ServerStatusColor.partial.color
    case .noneAvailable: return ServerStatusColor.offline.color
    case .notChecked: return ServerStatusColor.inactive.color
    }
  }

  private var showsHeader: Bool {
    switch entry.presentation.content {
    case .setupRequired, .noServers: return false
    case .statistics, .unavailable: return true
    }
  }

  private var hasHealthyServer: Bool {
    entry.presentation.availability == .allAvailable || entry.presentation.availability == .someAvailable
  }

  private var unavailableText: String {
    entry.presentation.availability == .noneAvailable
      ? "Statistics Unavailable, all servers offline"
      : "Statistics unavailable"
  }

  private var accessibilityText: String {
    var parts: [String] = showsHeader ? [statusText] : []
    if hasHealthyServer {
      parts.append("24 hours")
    }
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
        parts.append(unavailableText)
      case .statistics:
        break
      }
    }
    return parts.joined(separator: ". ")
  }
}

// The app target compiles this file only to preview the view above; Xcode
// cannot host previews in a macOS widget extension.
#if !HOLEBERRY_APP_TARGET
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
#endif
