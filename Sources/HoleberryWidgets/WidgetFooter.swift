import Foundation
import HoleberryCore

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
