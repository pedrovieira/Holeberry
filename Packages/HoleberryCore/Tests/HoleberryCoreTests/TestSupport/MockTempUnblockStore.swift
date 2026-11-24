import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `TempUnblockStoring` with in-memory backing
/// state and call tracking.
///
/// Nothing here touches real defaults. Tests use it to prove that an on-demand
/// service never loads, saves, or reconciles temporary-unblock records.
@MainActor
final class MockTempUnblockStore: TempUnblockStoring {
  var temporaryUnblocks: [UUID: [TempUnblockRecord]] = [:]

  private(set) var loadTemporaryUnblocksCallCount = 0
  private(set) var loadTemporaryUnblocksLastServerID: UUID?
  private(set) var saveTemporaryUnblocksCallCount = 0
  private(set) var saveTemporaryUnblocksLastArgs: (records: [TempUnblockRecord], serverID: UUID)?

  func loadTemporaryUnblocks(for serverID: UUID) -> [TempUnblockRecord] {
    loadTemporaryUnblocksCallCount += 1
    loadTemporaryUnblocksLastServerID = serverID
    return temporaryUnblocks[serverID] ?? []
  }

  func saveTemporaryUnblocks(_ records: [TempUnblockRecord], for serverID: UUID) {
    saveTemporaryUnblocksCallCount += 1
    saveTemporaryUnblocksLastArgs = (records, serverID)
    temporaryUnblocks[serverID] = records
  }
}
