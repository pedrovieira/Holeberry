import Foundation

/// Display-ready widget state derived from one live fetch summary.
public struct WidgetPresentation: Equatable, Sendable {
  public enum Content: Equatable, Sendable {
    case setupRequired
    case noServers
    case statistics(WidgetQueryStatistics)
    case unavailable
  }

  public let content: Content
  public let health: WidgetHealth
  public let lastCheckedAt: Date?

  public static let setupRequired = WidgetPresentation(
    content: .setupRequired,
    health: .notChecked,
    lastCheckedAt: nil
  )

  public init(
    summary: WidgetSummary,
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
      self.health = summary.health
    } else {
      self.health = .notChecked
    }
    self.lastCheckedAt = summary.checkedAt
  }

  public var statistics: WidgetQueryStatistics? {
    guard case .statistics(let statistics) = content else { return nil }
    return statistics
  }

  private init(content: Content, health: WidgetHealth, lastCheckedAt: Date?) {
    self.content = content
    self.health = health
    self.lastCheckedAt = lastCheckedAt
  }
}
