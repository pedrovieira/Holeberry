import Foundation
import HoleberryCore
import WidgetKit

/// One scoped query snapshot and its presentation at the timeline render date.
struct QueryStatisticsEntry: TimelineEntry, Sendable {
  enum Content: Equatable, Sendable {
    case setupRequired
    case noServers
    case unavailable
    case statistics
    case serverRemoved
    /// The stored selection cannot name a server; editing the widget fixes it.
    case editWidget
  }

  let date: Date
  let base: QueryStatisticsSnapshot

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

  /// Whether this widget targets one selected server.
  var isScopedToServer: Bool {
    if case .server = base.scope { return true }
    return false
  }

  /// The selected server's current display name; nil for the aggregate scope.
  var selectedServerName: String? {
    guard isScopedToServer else { return nil }
    return base.servers.first?.displayName
  }

  /// Whether the stored selection cannot name any server, so no server may be
  /// contacted or displayed for it.
  var hasUnreadableSelection: Bool {
    base.scope == .noTarget
  }

  var content: Content {
    // Editing the widget is the only remedy for an unreadable selection, so it
    // outranks the setup guidance that storage alone would produce.
    if hasUnreadableSelection { return .editWidget }
    if base.setupRequired { return .setupRequired }
    guard !base.observations.isEmpty else {
      return isScopedToServer ? .serverRemoved : .noServers
    }
    return summary == nil ? .unavailable : .statistics
  }

  var statusText: String {
    if hasUnreadableSelection { return "No server selected" }
    if isScopedToServer {
      if let selectedServerName { return selectedServerName }
      return base.setupRequired ? "Server" : "Server removed"
    }
    switch availability {
    case .allAvailable: return "All servers online"
    case .someAvailable: return "Some servers unavailable"
    case .noneAvailable: return "All servers unavailable"
    case .notChecked: return "All servers"
    }
  }

  /// Availability wording for accessibility. The aggregate header already
  /// describes availability, but a single server's name does not.
  var availabilityAccessibilityText: String {
    switch availability {
    case .allAvailable: return "Available"
    case .someAvailable: return "Partially available"
    case .noneAvailable: return "Unavailable"
    case .notChecked: return "Availability not checked"
    }
  }

  /// VoiceOver text for the widget's current content.
  ///
  /// A single server includes its name and availability, so a failed or
  /// expired check is never announced as healthy.
  var accessibilityText: String {
    switch content {
    case .setupRequired:
      return "Open Holeberry to finish setup"
    case .noServers:
      return "Add a server in Holeberry"
    case .serverRemoved:
      return "Server removed. Edit widget to choose another server"
    case .editWidget:
      return "Edit widget to choose a server"
    case .statistics, .unavailable:
      break
    }

    var parts: [String] = []
    if isScopedToServer {
      if let selectedServerName { parts.append(selectedServerName) }
      parts.append(availabilityAccessibilityText)
    } else {
      parts.append(statusText)
    }
    if hasHealthyServer {
      parts.append("24 hours")
    }

    if let summary, content == .statistics {
      let percentage = summary.blockedPercentage.formatted(
        .number.precision(.fractionLength(1))
      )
      parts.append("\(percentage) percent block rate")
      parts.append("\(summary.totalQueries.formatted(.number)) queries")
      parts.append("\(summary.totalBlocked.formatted(.number)) blocked")
      if let lastCheckedAt {
        parts.append(Self.updatedText(for: lastCheckedAt))
      }
    } else {
      parts.append("Statistics unavailable")
    }
    return parts.joined(separator: ". ")
  }

  private var hasHealthyServer: Bool {
    availability == .allAvailable || availability == .someAvailable
  }

  private static func updatedText(for date: Date) -> String {
    let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
    return String(format: "Updated %02dh%02d", components.hour ?? 0, components.minute ?? 0)
  }

  static func placeholder(
    now: Date = Date(),
    scope: ServerScope = .all,
    serverName: String? = nil
  ) -> QueryStatisticsEntry {
    let server = ServerConfig(
      id: placeholderServerID(for: scope),
      label: serverName,
      url: "https://example.invalid",
      version: .v6
    )
    let observations = ServerQueryObservation.make(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 184_200, totalBlocked: 31_200))],
      checkedAt: now
    )
    return QueryStatisticsEntry(
      date: now,
      base: QueryStatisticsSnapshot(
        scope: scope,
        setupRequired: false,
        observations: observations
      )
    )
  }

  static func setupRequired(now: Date = Date(), scope: ServerScope = .all) -> QueryStatisticsEntry {
    QueryStatisticsEntry(
      date: now,
      base: QueryStatisticsSnapshot(scope: scope, setupRequired: true, observations: [])
    )
  }

  /// An entry with no observations: no saved servers, or a removed selection.
  static func empty(now: Date = Date(), scope: ServerScope = .all) -> QueryStatisticsEntry {
    QueryStatisticsEntry(
      date: now,
      base: QueryStatisticsSnapshot(scope: scope, setupRequired: false, observations: [])
    )
  }

  /// A scoped placeholder must carry a matching server identifier, or snapshot
  /// normalization would filter its sample server away.
  private static func placeholderServerID(for scope: ServerScope) -> UUID {
    switch scope {
    case .all: return UUID()
    case .server(let id): return id
    case .noTarget: return UUID()
    }
  }
}
