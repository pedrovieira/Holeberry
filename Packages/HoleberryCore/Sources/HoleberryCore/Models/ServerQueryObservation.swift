import Foundation

/// One configured server's query-summary outcome for a single fetch batch.
///
/// Observations produced by ``make(servers:results:checkedAt:)`` share one batch
/// timestamp. A failed or missing result stays represented so a caller can show
/// the server's identity and failure state, while contributing no counts.
public struct ServerQueryObservation: Equatable, Sendable {
  /// The explicit outcome of one server in one fetch batch.
  public enum State: Equatable, Sendable {
    /// No fetch has completed for this server.
    case notChecked
    /// The server returned a query summary at the batch completion time.
    case success(QuerySummary, checkedAt: Date)
    /// The server returned no usable query summary at the batch completion time.
    case failure(PiholeError, checkedAt: Date)
  }

  public let server: ServerConfig
  public let state: State

  public init(server: ServerConfig, state: State) {
    self.server = server
    self.state = state
  }

  /// The batch completion time of this observation; nil before any check.
  public var checkedAt: Date? {
    switch state {
    case .notChecked: return nil
    case .success(_, let checkedAt), .failure(_, let checkedAt): return checkedAt
    }
  }

  /// Builds one observation per distinct configured server, in configuration order.
  ///
  /// Duplicate identifiers describe one server, so the first configuration wins.
  /// A nil `checkedAt` means the batch never ran: every server is not checked and
  /// `results` is ignored. A configured server without a completed result is an
  /// unavailable server, not an omission. Results for other servers are ignored.
  public static func make(
    servers: [ServerConfig],
    results: [UUID: Result<QuerySummary, PiholeError>],
    checkedAt: Date?
  ) -> [ServerQueryObservation] {
    var seenServerIDs: Set<UUID> = []
    var observations: [ServerQueryObservation] = []
    observations.reserveCapacity(servers.count)

    for server in servers {
      guard seenServerIDs.insert(server.id).inserted else { continue }
      guard let checkedAt else {
        observations.append(ServerQueryObservation(server: server, state: .notChecked))
        continue
      }
      observations.append(
        ServerQueryObservation(
          server: server,
          state: state(for: results[server.id], checkedAt: checkedAt)
        )
      )
    }

    return observations
  }

  /// Combined counts from the successful observations, or nil when none succeeded.
  ///
  /// Failures, missing results, and unchecked observations contribute no values.
  /// Duplicate identifiers count once, keeping the first occurrence. Checked
  /// integer addition returns nil on overflow rather than trapping or reporting a
  /// partial total. The combined summary has no defined gravity timestamp.
  public static func aggregate(_ observations: [ServerQueryObservation]) -> QuerySummary? {
    var seenServerIDs: Set<UUID> = []
    var totalQueries = 0
    var totalBlocked = 0
    var successCount = 0

    for observation in observations {
      guard seenServerIDs.insert(observation.server.id).inserted else { continue }
      guard case .success(let summary, _) = observation.state else { continue }

      let (queries, queriesOverflowed) = totalQueries.addingReportingOverflow(summary.totalQueries)
      let (blocked, blockedOverflowed) = totalBlocked.addingReportingOverflow(summary.totalBlocked)
      guard !queriesOverflowed, !blockedOverflowed else { return nil }

      successCount += 1
      totalQueries = queries
      totalBlocked = blocked
    }

    guard successCount > 0 else { return nil }
    return QuerySummary(totalQueries: totalQueries, totalBlocked: totalBlocked, gravityLastUpdated: nil)
  }

  /// Availability of the batch, derived only from query-summary outcomes.
  ///
  /// Blocking state is deliberately excluded. Empty and entirely unchecked inputs
  /// are not checked. Otherwise the result is the successful proportion of all
  /// distinct configured servers, so a not-checked server keeps the batch short of
  /// ``QueryStatisticsAvailability/allAvailable`` and missing results count as
  /// unavailable.
  public static func availability(
    in observations: [ServerQueryObservation]
  ) -> QueryStatisticsAvailability {
    var seenServerIDs: Set<UUID> = []
    var distinctServerCount = 0
    var checkedCount = 0
    var successCount = 0

    for observation in observations {
      guard seenServerIDs.insert(observation.server.id).inserted else { continue }
      distinctServerCount += 1
      switch observation.state {
      case .notChecked:
        continue
      case .success:
        checkedCount += 1
        successCount += 1
      case .failure:
        checkedCount += 1
      }
    }

    guard checkedCount > 0 else { return .notChecked }
    if successCount == distinctServerCount { return .allAvailable }
    if successCount == 0 { return .noneAvailable }
    return .someAvailable
  }

  private static let missingResultDescription = "Missing query summary result"

  private static func state(
    for result: Result<QuerySummary, PiholeError>?,
    checkedAt: Date
  ) -> State {
    switch result {
    case .success(let summary)?:
      return .success(summary, checkedAt: checkedAt)
    case .failure(let error)?:
      return .failure(error, checkedAt: checkedAt)
    case nil:
      return .failure(.unknown(missingResultDescription), checkedAt: checkedAt)
    }
  }
}
