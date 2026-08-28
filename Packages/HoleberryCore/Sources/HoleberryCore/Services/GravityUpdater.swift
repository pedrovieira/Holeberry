import Foundation
import OSLog

/// Result of a gravity update attempt for a single server.
public enum GravityUpdateOutcome: Equatable, Sendable {
  /// Request completed and the server's gravity timestamp moved.
  case succeeded
  /// Request completed but the gravity timestamp did not move — the update
  /// likely failed server-side.
  case noChange
  /// The request itself failed (network, auth, server error).
  case failed(PiholeError)
}

/// Owns the gravity update state machine (trigger → verify → re-check →
/// watchdog) and its observed completion times.
@MainActor
public protocol GravityUpdating: AnyObject {
  /// True while an update runs (trigger + verification).
  var isUpdating: Bool { get }

  /// App-observed completion times; display clamps to these.
  var completedAt: [UUID: Date] { get }

  /// Triggers a gravity update on all servers, verifies timestamps moved;
  /// unsupported servers are ignored. Concurrent triggers are ignored.
  @discardableResult
  func applyUpdate() async -> [UUID: GravityUpdateOutcome]

  /// Drops recorded state for servers that no longer exist.
  func prune(keeping serverIDs: Set<UUID>)
}

/// Default `GravityUpdating` implementation; one per process, owned by `ServerStatusPoller`.
@MainActor
public final class LiveGravityUpdater: GravityUpdating {
  public private(set) var isUpdating = false
  public private(set) var completedAt: [UUID: Date] = [:]

  /// Re-entrancy guard for the whole update; separate from the user-visible `isUpdating`.
  private var operationInFlight = false

  private let logger = Logger(subsystem: Logger.appSubsystem, category: "gravity")
  private let manager: any PiholeServerManaging
  private let sleep: (TimeInterval) async throws -> Void
  /// Hard cap: URLSession's timeout is idle-only. Above the v6 request's 900s
  /// timeout, so the watchdog catches only slow-but-alive streams.
  private let gravityTriggerTimeout: TimeInterval
  /// FTL refreshes cached `last_update` on a ~1s tick; wait this long before re-verifying.
  private static let gravityVerificationDelay: TimeInterval = 2

  public init(
    manager: any PiholeServerManaging,
    sleep: @escaping (TimeInterval) async throws -> Void = {
      try await sleepForSeconds($0)
    },
    gravityTriggerTimeout: TimeInterval = 16 * 60
  ) {
    self.manager = manager
    self.sleep = sleep
    self.gravityTriggerTimeout = gravityTriggerTimeout
  }

  @discardableResult
  public func applyUpdate() async -> [UUID: GravityUpdateOutcome] {
    guard !operationInFlight else { return [:] }
    operationInFlight = true
    defer { operationInFlight = false }

    let serverIDs = Set(manager.servers.map(\.id))
    guard !serverIDs.isEmpty else { return [:] }

    // Fresh before-snapshot
    let beforeSummaries = await manager.getQuerySummary()

    isUpdating = true
    defer { isUpdating = false }

    let results = await triggerGravityWithWatchdog(serverIDs: serverIDs, timeout: gravityTriggerTimeout)

    // Unsupported servers must never be reported as failures.
    let actionableResults = results.filter { _, result in
      guard case .failure(let error) = result else { return true }
      if case .unsupported = error { return false }
      return true
    }

    // Re-fetch summaries so outcomes compare against post-run data.
    var afterSummaries = await manager.getQuerySummary()

    // FTL can lag; re-check once after a short delay when movement isn't confirmed.
    if needsGravityRecheck(
      results: actionableResults,
      beforeSummaries: beforeSummaries,
      afterSummaries: afterSummaries
    ) {
      try? await sleep(Self.gravityVerificationDelay)
      let refreshed = await manager.getQuerySummary()
      for (id, summary) in refreshed {
        if let summary {
          afterSummaries[id] = summary
        }
      }
    }

    return computeGravityOutcomes(
      results: actionableResults,
      beforeSummaries: beforeSummaries,
      afterSummaries: afterSummaries
    )
  }

  public func prune(keeping serverIDs: Set<UUID>) {
    completedAt = completedAt.filter { serverIDs.contains($0.key) }
  }

  /// Maps results to outcomes, recording app-observed completion times.
  private func computeGravityOutcomes(
    results: [UUID: Result<Void, PiholeError>],
    beforeSummaries: [UUID: QuerySummary?],
    afterSummaries: [UUID: QuerySummary?]
  ) -> [UUID: GravityUpdateOutcome] {
    var outcomes: [UUID: GravityUpdateOutcome] = [:]
    for (id, result) in results {
      switch result {
      case .success:
        // The manager stores fetch failures as [id: nil]; either way the
        // summary is unavailable, so the run can't be confirmed.
        guard let after = afterSummaries[id].flatMap({ $0 }) else {
          outcomes[id] = .failed(.network("Could not verify gravity update — check the Pi-hole web interface"))
          continue
        }
        let beforeValue = beforeSummaries[id]?.flatMap { $0.gravityLastUpdated }
        let afterValue = after.gravityLastUpdated
        if beforeValue != afterValue {
          outcomes[id] = .succeeded
          completedAt[id] = Date()
        } else {
          outcomes[id] = .noChange
        }
      case .failure(let error):
        outcomes[id] = .failed(error)
      }
    }
    return outcomes
  }

  /// Whether a successful trigger's timestamp movement still needs re-verifying.
  private func needsGravityRecheck(
    results: [UUID: Result<Void, PiholeError>],
    beforeSummaries: [UUID: QuerySummary?],
    afterSummaries: [UUID: QuerySummary?]
  ) -> Bool {
    results.contains { id, result in
      guard case .success = result else { return false }
      let before = beforeSummaries[id]?.flatMap { $0.gravityLastUpdated }
      let after = afterSummaries[id]?.flatMap { $0.gravityLastUpdated }
      return after == nil || after == before
    }
  }

  /// Runs the trigger against the watchdog; on timeout the request is cancelled and every server fails.
  private func triggerGravityWithWatchdog(
    serverIDs: Set<UUID>,
    timeout: TimeInterval
  ) async -> [UUID: Result<Void, PiholeError>] {
    do {
      return try await withThrowingTaskGroup(of: [UUID: Result<Void, PiholeError>].self) { group in
        // Via `self` so the non-Sendable manager stays off the `@Sendable` child.
        group.addTask { await self.manager.updateGravity() }
        group.addTask {
          try await self.sleepForGravityTimeout(timeout)
          throw PiholeError.unknown(
            "timed out after \(Int(timeout / 60)) minutes — may still finish on the Pi-hole; check its web interface"
          )
        }
        guard let first = try await group.next() else {
          throw PiholeError.unknown("Gravity trigger produced no result")
        }
        group.cancelAll()
        return first
      }
    } catch {
      // Watchdog fired or the trigger was cancelled: report and move on.
      logger.warning("Gravity trigger aborted: \(error.localizedDescription, privacy: .public)")
      let piholeError = error as? PiholeError ?? PiholeError.unknown(error.localizedDescription)
      return Dictionary(uniqueKeysWithValues: serverIDs.map { ($0, .failure(piholeError)) })
    }
  }

  /// Keeps the non-Sendable `sleep` out of the `@Sendable` watchdog task.
  private func sleepForGravityTimeout(_ timeout: TimeInterval) async throws {
    try await sleep(timeout)
  }
}
