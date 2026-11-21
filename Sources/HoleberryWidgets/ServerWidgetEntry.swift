import Foundation
import HoleberryCore
import WidgetKit

/// The display state shared by every query-statistics widget.
enum ServerWidgetContent: Equatable, Sendable {
  case setupRequired
  case noServers
  case unavailable
  case statistics
}

/// A widget timeline entry backed by one scoped query snapshot.
///
/// Concrete widgets store their rendering date and the shared
/// ``QueryStatisticsSnapshot``, then add whatever payload that widget needs.
/// The defaults below keep setup precedence, data claims, availability expiry,
/// and display copy identical across every widget.
protocol ServerWidgetEntry: TimelineEntry, Sendable {
  var base: QueryStatisticsSnapshot { get }
}

extension ServerWidgetEntry {
  /// Joint counts from the servers that succeeded in this batch.
  var summary: QuerySummary? {
    base.summary
  }

  /// Completion time of this batch; nil before any check or during setup.
  var lastCheckedAt: Date? {
    base.lastCheckedAt
  }

  /// Availability for this entry's render date.
  var availability: QueryStatisticsAvailability {
    base.availability(at: date)
  }

  var content: ServerWidgetContent {
    if base.setupRequired { return .setupRequired }
    guard !base.observations.isEmpty else { return .noServers }
    return summary == nil ? .unavailable : .statistics
  }

  var statusText: String {
    switch availability {
    case .allAvailable: return "All servers online"
    case .someAvailable: return "Some servers unavailable"
    case .noneAvailable: return "All servers unavailable"
    case .notChecked: return "All servers"
    }
  }
}
