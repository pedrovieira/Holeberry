import Foundation
import HoleberryCore
import SwiftUI
import WidgetKit

struct ServerStatisticsGlanceWidgetEntryView: View {
  let entry: QueryStatisticsEntry

  @Environment(\.colorScheme) private var colorScheme

  private static let nominalCardSide: CGFloat = 160
  private static let contentInset: CGFloat = 17
  private static let bottomInset: CGFloat = 13
  private static let dividerSpacing: CGFloat = 5
  private static let middleGap: CGFloat = 8
  private static let unavailableText = "Statistics unavailable"

  var body: some View {
    GeometryReader { proxy in
      let scale = max(proxy.size.width / Self.nominalCardSide, 0.1)
      content(scale: scale)
    }
    .containerBackground(for: .widget) {
      WidgetBrandColor.tileGradient(for: colorScheme)
    }
    .widgetURL(AppDeepLink.settingsURL)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
  }

  @ViewBuilder
  private func content(scale: CGFloat) -> some View {
    switch entry.content {
    case .statistics:
      VStack(alignment: .leading, spacing: 0) {
        header(scale: scale)
        if let summary = entry.summary {
          statisticsContent(summary, scale: scale)
        }
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
      guidance(Self.unavailableText, scale: scale)
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
      if entry.availability != .noneAvailable {
        Text(entry.statusText)
          .font(.system(size: 8.5 * scale, weight: .semibold))
          .foregroundStyle(brand(.primaryText))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
      Spacer(minLength: 4 * scale)
      if hasHealthyServer {
        Text("24h")
          .font(.system(size: 9 * scale, weight: .semibold))
          .foregroundStyle(brand(.secondaryText))
          .lineLimit(1)
          .fixedSize()
      }
    }
    .frame(height: 12 * scale)
  }

  @ViewBuilder
  private func statisticsContent(_ summary: QuerySummary, scale: CGFloat) -> some View {
    hero(summary, scale: scale)
    Text("block rate")
      .font(.system(size: 10 * scale, weight: .semibold))
      .foregroundStyle(brand(.secondaryText))
      .lineLimit(1)
      .padding(.top, -1 * scale)
    horizontalSeparator(scale: scale)
      .padding(.top, Self.dividerSpacing * scale)
    metrics(summary, scale: scale)
      .padding(.top, Self.dividerSpacing * scale)
    Spacer(minLength: 6 * scale)
    footer(scale: scale)
  }

  private func hero(_ summary: QuerySummary, scale: CGFloat) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 1 * scale) {
      Text(summary.blockedPercentage, format: .number.precision(.fractionLength(1)))
        .font(.system(size: 42 * scale, weight: .regular))
        .foregroundStyle(brand(.primaryText))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
      Text(verbatim: "%")
        .font(.system(size: 20 * scale, weight: .regular))
        .foregroundStyle(brand(.secondaryText))
        .lineLimit(1)
    }
  }

  private func metrics(_ summary: QuerySummary, scale: CGFloat) -> some View {
    HStack(alignment: .center, spacing: 0) {
      metricColumn(
        value: summary.totalQueries,
        caption: "Queries",
        color: brand(.primaryText),
        scale: scale
      )
      .frame(maxWidth: .infinity, alignment: .leading)

      Rectangle()
        .fill(brand(.divider))
        .frame(width: 0.5 * scale, height: 20 * scale)

      metricColumn(
        value: summary.totalBlocked,
        caption: "Blocked",
        color: brand(.blocked),
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
        .font(.system(size: 13.5 * scale, weight: .medium))
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      Text(caption)
        .font(.system(size: 10 * scale, weight: .regular))
        .foregroundStyle(brand(.secondaryText))
        .lineLimit(1)
    }
  }

  private func horizontalSeparator(scale: CGFloat) -> some View {
    Rectangle()
      .fill(brand(.divider))
      .frame(maxWidth: .infinity)
      .frame(height: 0.5 * scale)
  }

  @ViewBuilder
  private func footer(scale: CGFloat) -> some View {
    if let lastCheckedAt = entry.lastCheckedAt {
      Text(verbatim: WidgetFooter.text(observedAt: lastCheckedAt, renderedAt: entry.date))
        .font(.system(size: 9 * scale, weight: .medium))
        .foregroundStyle(brand(.secondaryText))
        .lineLimit(1)
        .multilineTextAlignment(.leading)
    }
  }

  private func guidance(_ text: String, scale: CGFloat) -> some View {
    VStack(spacing: 12 * scale) {
      Image("holeberry-logo")
        .resizable()
        .scaledToFit()
        .frame(width: 40 * scale, height: 40 * scale)
        .accessibilityHidden(true)
      Text(text)
        .font(.system(size: 10 * scale, weight: .medium))
        .foregroundStyle(brand(.secondaryText))
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

  private func brand(_ color: WidgetBrandColor) -> Color {
    color.color(for: colorScheme)
  }

  private var healthColor: Color {
    switch entry.availability {
    case .allAvailable: return ServerStatusColor.healthy.color
    case .someAvailable: return ServerStatusColor.partial.color
    case .noneAvailable: return ServerStatusColor.offline.color
    case .notChecked: return ServerStatusColor.inactive.color
    }
  }

  private var showsHeader: Bool {
    switch entry.content {
    case .setupRequired, .noServers: return false
    case .statistics, .unavailable: return true
    }
  }

  private var hasHealthyServer: Bool {
    entry.availability == .allAvailable || entry.availability == .someAvailable
  }

  private var accessibilityText: String {
    var parts: [String] = showsHeader ? [entry.statusText] : []
    if hasHealthyServer {
      parts.append("24 hours")
    }
    if let summary = entry.summary, entry.content == .statistics {
      let percentage = summary.blockedPercentage.formatted(
        .number.precision(.fractionLength(1))
      )
      parts.append("\(percentage) percent block rate")
      parts.append("\(summary.totalQueries.formatted(.number)) queries")
      parts.append("\(summary.totalBlocked.formatted(.number)) blocked")
      if let lastCheckedAt = entry.lastCheckedAt {
        parts.append(Self.updatedText(for: lastCheckedAt))
      }
    } else {
      switch entry.content {
      case .setupRequired:
        parts.append("Open Holeberry to finish setup")
      case .noServers:
        parts.append("Add a server in Holeberry")
      case .unavailable:
        parts.append(Self.unavailableText)
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
  struct ServerStatisticsGlanceWidget: Widget {
    // The Swift type was renamed; this kind is persisted for widgets that are
    // already installed, so it must not follow the type name.
    let kind = "AllServersWidget"

    var body: some WidgetConfiguration {
      StaticConfiguration(kind: kind, provider: QueryStatisticsProvider(scope: .all)) { entry in
        ServerStatisticsGlanceWidgetEntryView(entry: entry)
      }
      .configurationDisplayName("All servers")
      .description("Block rate and query totals for all Pi-hole servers.")
      .supportedFamilies([.systemSmall])
      .contentMarginsDisabled()
    }
  }
#endif
