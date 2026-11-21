import Foundation

/// One scoped query-summary batch shared by every query-statistics widget.
///
/// The snapshot stores only source state: the scope it was fetched for, whether
/// setup is still required, and one observation per in-scope server. Combined
/// counts, the batch check time, and availability are derived, so no duplicate
/// totals or rendering date are retained. WidgetKit types stay out of Core.
public struct QueryStatisticsSnapshot: Equatable, Sendable {
  /// The age at which availability stops describing the last check.
  public static let availabilityExpiration: TimeInterval = 60 * 60

  public let scope: ServerScope
  public let setupRequired: Bool
  public let observations: [ServerQueryObservation]

  /// Filters observations to `scope` and keeps the first occurrence of each server UUID.
  public init(
    scope: ServerScope,
    setupRequired: Bool,
    observations: [ServerQueryObservation]
  ) {
    self.scope = scope
    self.setupRequired = setupRequired
    self.observations = Self.normalized(scope: scope, observations: observations)
  }

  /// The in-scope configured servers, in observation order.
  public var servers: [ServerConfig] {
    observations.map(\.server)
  }

  /// Joint counts from the servers that succeeded in this batch.
  ///
  /// Setup-required snapshots expose no data claim. Failed, missing, and
  /// unchecked observations contribute nothing.
  public var summary: QuerySummary? {
    guard !setupRequired else { return nil }
    return ServerQueryObservation.aggregate(observations)
  }

  /// Completion time of this batch, including an all-failure batch.
  ///
  /// Setup-required snapshots expose no data claim. Nil before any check.
  public var lastCheckedAt: Date? {
    guard !setupRequired else { return nil }
    return observations.compactMap(\.checkedAt).max()
  }

  /// Availability for a widget rendered at `date`.
  ///
  /// The result is derived from the batch outcomes until exactly
  /// ``availabilityExpiration`` seconds after the check; after that it is
  /// `notChecked`. Counts and observation times are left untouched, so a delayed
  /// render keeps the last successful values with their original fetch time.
  public func availability(at date: Date) -> QueryStatisticsAvailability {
    guard !setupRequired,
      let lastCheckedAt,
      date.timeIntervalSince(lastCheckedAt) < Self.availabilityExpiration
    else {
      return .notChecked
    }
    return ServerQueryObservation.availability(in: observations)
  }

  private static func normalized(
    scope: ServerScope,
    observations: [ServerQueryObservation]
  ) -> [ServerQueryObservation] {
    let scoped: [ServerQueryObservation]
    switch scope {
    case .all:
      scoped = observations
    case .server(let id):
      scoped = observations.filter { $0.server.id == id }
    }

    // A duplicate UUID describes one server, so the first observation supplies
    // its configuration, state, and timestamp.
    var seenServerIDs: Set<UUID> = []
    return scoped.filter { seenServerIDs.insert($0.server.id).inserted }
  }
}
