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

  private init(content: Content, availability: QueryStatisticsAvailability, lastCheckedAt: Date?) {
    self.content = content
    self.availability = availability
    self.lastCheckedAt = lastCheckedAt
  }
}
