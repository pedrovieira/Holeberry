import Foundation

/// Formats how long ago a date was.
///
/// One implementation for the menu, the connection card, and the widget.
public struct RelativeAgeFormatter: Sendable {
  /// When `.standardWithMoments` switches from its moments text to whole units.
  public static let momentsThreshold: TimeInterval = 60

  public enum Style: Sendable {
    /// Locale-aware short units; may include seconds ("10 sec. ago").
    case standard
    /// "a few moments ago" under one minute, then `.standard`.
    case standardWithMoments
    /// Locale-aware short units with whole minutes, floored at one minute
    /// ("1 min. ago", never "35 sec. ago").
    case wholeMinutes
    /// Fixed English whole units without seconds: "moments ago", "1min ago",
    /// "1h ago", "1d ago". Widget text must stay stable between renders, so it
    /// never shows seconds or needs a live format style.
    case compact
  }

  public let style: Style
  public let locale: Locale

  public init(style: Style = .standard, locale: Locale = .autoupdatingCurrent) {
    self.style = style
    self.locale = locale
  }

  /// Text for the age of `date`, measured from `now`.
  public func string(since date: Date, relativeTo now: Date = Date()) -> String {
    switch style {
    case .standard:
      return localizedString(since: date, relativeTo: now, unitsStyle: .short)
    case .standardWithMoments:
      if now.timeIntervalSince(date) < Self.momentsThreshold {
        return "a few moments ago"
      }
      return localizedString(since: date, relativeTo: now, unitsStyle: .short)
    case .wholeMinutes:
      let minutes = max(1, Int(now.timeIntervalSince(date) / 60))
      let wholeMinuteDate = now.addingTimeInterval(-TimeInterval(minutes) * 60)
      return localizedString(since: wholeMinuteDate, relativeTo: now, unitsStyle: .short)
    case .compact:
      return compactString(since: date, relativeTo: now)
    }
  }

  private func localizedString(
    since date: Date,
    relativeTo now: Date,
    unitsStyle: RelativeDateTimeFormatter.UnitsStyle
  ) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.dateTimeStyle = .numeric
    formatter.unitsStyle = unitsStyle
    return formatter.localizedString(for: date, relativeTo: now)
  }

  private func compactString(since date: Date, relativeTo now: Date) -> String {
    let elapsed = max(0, now.timeIntervalSince(date))
    // Tolerate floating-point error when a timeline entry lands exactly on a
    // minute boundary.
    let minutes = Int((elapsed + 0.000_001) / 60)
    guard minutes >= 1 else { return "moments ago" }
    guard minutes >= 60 else { return "\(minutes)min ago" }

    let hours = minutes / 60
    guard hours >= 24 else { return "\(hours)h ago" }

    return "\(hours / 24)d ago"
  }
}
