import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `GravityUpdating` with stub injection and
/// call-count tracking.
@MainActor
final class MockGravityUpdater: GravityUpdating {
  var isUpdating = false
  var completedAt: [UUID: Date] = [:]

  var applyUpdateResult: [UUID: GravityUpdateOutcome] = [:]
  private(set) var applyUpdateCallCount = 0
  /// One-shot: the next `applyUpdate()` awaits this before returning.
  var applyUpdateGate: (@MainActor () async -> Void)?

  private(set) var prunedServerIDs: Set<UUID>?

  func applyUpdate() async -> [UUID: GravityUpdateOutcome] {
    applyUpdateCallCount += 1
    if let gate = applyUpdateGate {
      applyUpdateGate = nil
      await gate()
    }
    return applyUpdateResult
  }

  func prune(keeping serverIDs: Set<UUID>) {
    prunedServerIDs = serverIDs
  }
}
