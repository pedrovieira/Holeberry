import Foundation

/// Scoped query results shared by widgets.
/// Counts, check time, and availability are derived from source observations.
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

  /// Aggregates successful observations; returns nil during setup.
  public var summary: QuerySummary? {
    guard !setupRequired else { return nil }
    return ServerQueryObservation.aggregate(observations)
  }

  /// Latest check time, including failures; nil before a check or during setup.
  public var lastCheckedAt: Date? {
    guard !setupRequired else { return nil }
    return observations.compactMap(\.checkedAt).max()
  }

  /// Availability from the check time until ``availabilityExpiration`` seconds later.
  /// Outside that interval, returns `notChecked` without changing counts or fetch times.
  public func availability(at date: Date) -> QueryStatisticsAvailability {
    guard !setupRequired,
      let lastCheckedAt,
      date >= lastCheckedAt,
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
    case .noTarget:
      scoped = []
    }

    // The first occurrence supplies the configuration, result, and timestamp.
    var seenServerIDs: Set<UUID> = []
    return scoped.filter { seenServerIDs.insert($0.server.id).inserted }
  }
}
