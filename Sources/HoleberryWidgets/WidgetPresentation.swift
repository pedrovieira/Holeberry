import Foundation
import HoleberryCore

/// Display-ready widget state derived from one live fetch summary.
struct WidgetPresentation: Equatable, Sendable {
  enum Content: Equatable, Sendable {
    case setupRequired
    case noServers
    case statistics(QueryStatistics)
    case unavailable
  }

  let content: Content
  let availability: QueryStatisticsAvailability
  let lastCheckedAt: Date?

  static let setupRequired = WidgetPresentation(
    content: .setupRequired,
    availability: .notChecked,
    lastCheckedAt: nil
  )

  init(
    summary: QueryStatisticsFetchResult,
    now: Date,
    expirationInterval: TimeInterval = 60 * 60
  ) {
    if summary.servers.isEmpty {
      self.content = .noServers
    } else if let statistics = summary.completedStatistics {
      self.content = .statistics(statistics)
    } else {
      self.content = .unavailable
    }

    if let checkedAt = summary.checkedAt,
      now.timeIntervalSince(checkedAt) < expirationInterval
    {
      self.availability = summary.availability
    } else {
      self.availability = .notChecked
    }
    self.lastCheckedAt = summary.checkedAt
  }

  var statistics: QueryStatistics? {
    guard case .statistics(let statistics) = content else { return nil }
    return statistics
  }

  var statusText: String {
    switch availability {
    case .allAvailable: return "All servers online"
    case .someAvailable: return "Some servers unavailable"
    case .noneAvailable: return "All servers unavailable"
    case .notChecked: return "All servers"
    }
  }

  private init(content: Content, availability: QueryStatisticsAvailability, lastCheckedAt: Date?) {
    self.content = content
    self.availability = availability
    self.lastCheckedAt = lastCheckedAt
  }
}

/// Static footer text plus the timeline entries that keep it current.
///
/// WidgetKit renders a timeline entry without running the widget extension, so
/// the footer cannot format itself when it appears. Native dynamic single-unit
/// relative text needs macOS 15 (`SystemFormatStyle.DateReference`), and
/// `Text(_:style: .relative)` is dynamic but multi-unit ("1 hr, 5 min"). The
/// timeline therefore carries entries that advance the formatted age even when
/// the next network refresh is delayed.
enum WidgetFooter {
  /// Footer text for the entry WidgetKit renders at `renderedAt`.
  static func text(
    observedAt: Date,
    renderedAt: Date,
    locale: Locale = .autoupdatingCurrent
  ) -> String {
    let relative = RelativeAgeFormatter(style: .standardWithMoments, locale: locale)
      .string(since: observedAt, relativeTo: renderedAt)
    return "Updated \(relative)"
  }

  /// Minute entries for the first hour, hourly entries through the first day,
  /// then daily entries through 30 days. Normal network refreshes are requested
  /// after 15 minutes; these entries cover delayed refreshes without new fetches.
  static func entryDates(observedAt: Date?, now: Date) -> [Date] {
    guard let observedAt else { return [] }

    var dates = Set<Date>()
    for minute in 1...60 {
      dates.insert(observedAt.addingTimeInterval(Double(minute) * 60))
    }
    for hour in 2...24 {
      dates.insert(observedAt.addingTimeInterval(Double(hour) * 60 * 60))
    }
    for day in 2...30 {
      dates.insert(observedAt.addingTimeInterval(Double(day) * 24 * 60 * 60))
    }
    return dates.filter { $0 > now }.sorted()
  }
}
