import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("LiveGravityUpdater")
struct GravityUpdaterTests {
  private let mockManager = MockPiholeServerManager()

  /// Small real sleep: the watchdog can't outrun the instant mock trigger; verification stays ~100ms.
  private func makeUpdater(
    timeout: TimeInterval = 15 * 60,
    sleep: @escaping (TimeInterval) async throws -> Void = { _ in
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
  ) -> LiveGravityUpdater {
    LiveGravityUpdater(manager: mockManager, sleep: sleep, gravityTriggerTimeout: timeout)
  }

  // MARK: - applyUpdate()

  @Test("applyUpdate succeeds when last_update moved")
  func applyUpdateSucceeded() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    let oldDate = Date(timeIntervalSince1970: 1_000)
    let newDate = Date(timeIntervalSince1970: 2_000)
    mockManager.getQuerySummaryResponses = [
      [id: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: oldDate)],
      [id: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: newDate)]
    ]
    mockManager.updateGravityStub = [id: .success(())]

    let updater = makeUpdater()
    let outcomes = await updater.applyUpdate()

    #expect(outcomes == [id: .succeeded])
    #expect(mockManager.updateGravityCallCount == 1)
    #expect(updater.isUpdating == false)
    #expect(updater.completedAt[id] != nil)
  }

  @Test("isUpdating stays true until applyUpdate finishes")
  func isUpdatingStaysTrueUntilFinished() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getQuerySummaryResponses = [
      [id: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: Date(timeIntervalSince1970: 1_000))],
      [id: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: Date(timeIntervalSince1970: 2_000))]
    ]
    mockManager.updateGravityStub = [id: .success(())]
    let updater = makeUpdater()

    // Runs during the post-trigger verification fetch.
    mockManager.getQuerySummaryGate = {
      #expect(updater.isUpdating)
    }

    let outcomes = await updater.applyUpdate()

    #expect(outcomes == [id: .succeeded])
    #expect(updater.isUpdating == false)
  }

  @Test("applyUpdate reports failure when the after-fetch and re-check fail")
  func unverifiableAfterFetchFails() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    let oldDate = Date(timeIntervalSince1970: 1_000)
    mockManager.getQuerySummaryResponses = [
      [id: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: oldDate)],
      [id: nil],
      [id: nil]
    ]
    mockManager.updateGravityStub = [id: .success(())]

    let updater = makeUpdater()
    let outcomes = await updater.applyUpdate()

    guard case .failed(let error) = outcomes[id] else {
      Issue.record("expected a verification failure, got \(String(describing: outcomes[id]))")
      return
    }
    #expect(error == .network("Could not verify gravity update — check the Pi-hole web interface"))
    #expect(updater.completedAt[id] == nil)
  }

  @Test("applyUpdate does not report noChange when both fetches fail")
  func bothFetchesFail() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getQuerySummaryResponses = [
      [id: nil],
      [id: nil],
      [id: nil]
    ]
    mockManager.updateGravityStub = [id: .success(())]

    let updater = makeUpdater()
    let outcomes = await updater.applyUpdate()

    guard case .failed = outcomes[id] else {
      Issue.record("expected a verification failure, got \(String(describing: outcomes[id]))")
      return
    }
  }

  @Test("applyUpdate aborts a hung trigger at the watchdog deadline")
  func watchdogTimeout() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    // Simulate a trigger that never returns until cancelled.
    mockManager.updateGravityGate = {
      try? await Task.sleep(nanoseconds: UInt64(60 * 1_000_000_000))
    }
    let updater = makeUpdater(timeout: 0.05)

    let outcomes = await updater.applyUpdate()

    guard case .failed = outcomes[id] else {
      Issue.record("expected a timeout failure, got \(String(describing: outcomes[id]))")
      return
    }
    #expect(updater.isUpdating == false)
    #expect(updater.completedAt[id] == nil)
  }

  @Test("applyUpdate reports noChange when last_update did not move")
  func noChange() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    let date = Date(timeIntervalSince1970: 1_000)
    // Third response feeds the delayed re-check.
    mockManager.getQuerySummaryResponses = [
      [id: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: date)],
      [id: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: date)],
      [id: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: date)]
    ]
    mockManager.updateGravityStub = [id: .success(())]

    let updater = makeUpdater()
    let outcomes = await updater.applyUpdate()

    #expect(outcomes == [id: .noChange])
    #expect(updater.completedAt[id] == nil)
  }

  @Test("applyUpdate re-checks a stale after-fetch and succeeds on retry")
  func rechecksStaleAfterFetch() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    let oldDate = Date(timeIntervalSince1970: 1_000)
    let newDate = Date(timeIntervalSince1970: 2_000)
    // Immediate after-fetch can lag; the delayed re-check sees the new one.
    mockManager.getQuerySummaryResponses = [
      [id: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: oldDate)],
      [id: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: oldDate)],
      [id: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: newDate)]
    ]
    mockManager.updateGravityStub = [id: .success(())]

    let updater = makeUpdater()
    let outcomes = await updater.applyUpdate()

    #expect(outcomes == [id: .succeeded])
    #expect(mockManager.getQuerySummaryCallCount == 3)
    #expect(updater.completedAt[id] != nil)
  }

  @Test("applyUpdate reports failure")
  func reportsFailure() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.updateGravityStub = [id: .failure(.network("down"))]

    let updater = makeUpdater()
    let outcomes = await updater.applyUpdate()

    #expect(outcomes == [id: .failed(.network("down"))])
  }

  @Test("applyUpdate ignores a second trigger while running")
  func concurrentGuard() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getQuerySummaryResponses = [
      [id: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: nil)],
      [id: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: Date())]
    ]
    mockManager.updateGravityStub = [id: .success(())]
    let updater = makeUpdater()

    // Hold the first update open; the second trigger arrives meanwhile.
    mockManager.updateGravityGate = {
      let second = await updater.applyUpdate()
      #expect(second.isEmpty)
      #expect(updater.isUpdating)
    }

    let outcomes = await updater.applyUpdate()

    #expect(outcomes == [id: .succeeded])
    #expect(updater.isUpdating == false)
    #expect(mockManager.updateGravityCallCount == 1)
  }

  @Test("applyUpdate ignores servers that report gravity as unsupported")
  func ignoresUnsupportedServers() async {
    let v6ID = UUID()
    let v5ID = UUID()
    mockManager.servers = [
      ServerConfig(id: v6ID, url: "http://a.local", version: .v6),
      ServerConfig(id: v5ID, url: "http://b.local", version: .v5)
    ]
    let oldDate = Date(timeIntervalSince1970: 1_000)
    let newDate = Date(timeIntervalSince1970: 2_000)
    mockManager.getQuerySummaryResponses = [
      [v6ID: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: oldDate)],
      [v6ID: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: newDate)]
    ]
    // Simulate an unsupported result slipping through the manager.
    mockManager.updateGravityStub = [
      v6ID: .success(()),
      v5ID: .failure(.unsupported("Gravity updates via API are not supported by Pi-hole v5"))
    ]

    let updater = makeUpdater()
    let outcomes = await updater.applyUpdate()

    #expect(outcomes == [v6ID: .succeeded])
    #expect(outcomes[v5ID] == nil)
  }

  @Test("prune drops completion records for removed servers")
  func pruneDropsRemovedServers() async {
    let kept = UUID()
    let removed = UUID()
    mockManager.servers = [
      ServerConfig(id: kept, url: "http://a.local", version: .v6),
      ServerConfig(id: removed, url: "http://b.local", version: .v6)
    ]
    let oldDate = Date(timeIntervalSince1970: 1_000)
    let newDate = Date(timeIntervalSince1970: 2_000)
    mockManager.getQuerySummaryResponses = [
      [
        kept: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: oldDate),
        removed: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: oldDate)
      ],
      [
        kept: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: newDate),
        removed: QuerySummary(totalQueries: 1, totalBlocked: 0, gravityLastUpdated: newDate)
      ]
    ]
    mockManager.updateGravityStub = [kept: .success(()), removed: .success(())]

    let updater = makeUpdater()
    _ = await updater.applyUpdate()
    #expect(updater.completedAt[kept] != nil)
    #expect(updater.completedAt[removed] != nil)

    updater.prune(keeping: [kept])

    #expect(updater.completedAt[removed] == nil)
    #expect(updater.completedAt[kept] != nil)
  }
}
