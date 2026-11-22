import Foundation

public struct QuerySummary: Equatable, Sendable {
  public let totalQueries: Int
  public let totalBlocked: Int
  public let gravityLastUpdated: Date?

  public init(totalQueries: Int, totalBlocked: Int, gravityLastUpdated: Date? = nil) {
    self.totalQueries = totalQueries
    self.totalBlocked = totalBlocked
    self.gravityLastUpdated = gravityLastUpdated
  }

  /// Weighted block rate for these counts. No queries safely produce zero.
  public var blockedPercentage: Double {
    guard totalQueries > 0 else { return 0 }
    return 100 * Double(totalBlocked) / Double(totalQueries)
  }
}
