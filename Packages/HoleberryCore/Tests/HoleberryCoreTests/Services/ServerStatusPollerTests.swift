import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("ServerStatusPoller")
struct ServerStatusPollerTests {
  private let mockManager = MockPiholeServerManager()
  private let mockNetwork = MockLocalIPAddressResolver()
  private let scheduler = MockPollScheduler()
  private let testSuite = TestDefaults.makeSuite()

  /// Creates a poller wired to the mocks above.
  ///
  /// Configure `mockManager.servers` BEFORE calling this unless the test exercises
  /// the `$servers` sink: the subscription drops the initial emission, so
  /// pre-seeding servers prevents an unexpected sink-triggered poll.
  private func makePoller() -> ServerStatusPoller {
    ServerStatusPoller(
      manager: mockManager,
      networkInterface: mockNetwork,
      pollingInterval: 3600,
      defaultsSuite: testSuite,
      scheduler: scheduler
    )
  }

  // MARK: - Polling Lifecycle

  @Test("starts with empty state")
  func startsWithEmptyState() {
    let poller = makePoller()
    #expect(poller.servers.isEmpty)
    #expect(poller.connectionStatuses.isEmpty)
    #expect(poller.blockingStatuses.isEmpty)
    #expect(poller.querySummaries.isEmpty)
  }

  @Test("startPolling begins polling")
  func startPollingBeginsPolling() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getBlockingStatusStub = [id: .enabled]
    let poller = makePoller()

    poller.startPolling()

    #expect(scheduler.startCount == 1)
    #expect(scheduler.lastInterval == 3600)

    await scheduler.fireTick()

    #expect(mockManager.getBlockingStatusCallCount == 1)
    #expect(poller.connectionStatuses[id] == .connected)
    #expect(poller.blockingStatuses[id] == .enabled)
  }

  @Test("startPolling while running is a no-op; stopPolling allows restart")
  func startPollingIdempotentAndRestartable() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getBlockingStatusStub = [id: .enabled]
    let poller = makePoller()

    poller.startPolling()
    poller.startPolling()
    #expect(scheduler.startCount == 1)
    #expect(scheduler.isRunning)

    poller.stopPolling()
    #expect(scheduler.isRunning == false)

    poller.startPolling()
    #expect(scheduler.startCount == 2)
  }

  @Test("stopPolling cancels the scheduler")
  func stopPollingCancelsTask() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getBlockingStatusStub = [id: .enabled]
    let poller = makePoller()

    poller.startPolling()
    await scheduler.fireTick()
    #expect(mockManager.getBlockingStatusCallCount == 1)

    poller.stopPolling()

    #expect(scheduler.stopCount == 1)
    #expect(scheduler.isRunning == false)

    // Ticks after stop are no-ops: no further polls occur.
    await scheduler.fireTick()
    #expect(mockManager.getBlockingStatusCallCount == 1)
  }

  @Test("empty servers clears state on poll")
  func emptyServersClearsStateOnPoll() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getBlockingStatusStub = [id: .enabled]
    mockManager.getQuerySummaryStub = [id: QuerySummary(totalQueries: 10, totalBlocked: 2)]
    mockManager.getRecentBlockedStub = .success(
      [BlockedDomain(domain: "ads.com", timestamp: Date(), fromClientIp: "1.1.1.1")]
    )
    let poller = makePoller()
    poller.startPolling()

    await scheduler.fireTick()
    #expect(poller.connectionStatuses.isEmpty == false)
    #expect(poller.recentBlocked.count == 1)

    // Removing all servers and polling again clears every published collection.
    mockManager.servers = []

    // Let the sink process the removal first: it prunes removed IDs and spawns its
    // own poll. A manual tick fired before that would race the pending pruning and
    // could re-populate state from the previous stubs.
    await waitUntil { poller.servers.isEmpty }
    await scheduler.fireTick()

    #expect(poller.servers.isEmpty)
    #expect(poller.connectionStatuses.isEmpty)
    #expect(poller.blockingStatuses.isEmpty)
    #expect(poller.querySummaries.isEmpty)
    #expect(poller.recentBlocked.isEmpty)
  }

  @Test("pollNow restarts polling and polls immediately")
  func pollNowRestartsPolling() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getBlockingStatusStub = [id: .enabled]
    let poller = makePoller()

    poller.startPolling()
    await scheduler.fireTick()
    #expect(mockManager.getBlockingStatusCallCount == 1)

    poller.pollNow()

    #expect(scheduler.startCount == 2)

    await scheduler.fireTick()
    #expect(mockManager.getBlockingStatusCallCount == 2)
  }

  // MARK: - Status Aggregation

  @Test("getBlockingStatus populates blocking statuses per server")
  func getBlockingStatusPopulatesBlockingStatuses() async {
    let idA = UUID()
    let idB = UUID()
    mockManager.servers = [
      ServerConfig(id: idA, url: "http://a.local", version: .v6),
      ServerConfig(id: idB, url: "http://b.local", version: .v6)
    ]
    mockManager.getBlockingStatusStub = [idA: .enabled, idB: .disabled(remainingSeconds: 120)]
    let poller = makePoller()
    poller.startPolling()

    await scheduler.fireTick()

    #expect(poller.blockingStatuses[idA] == .enabled)
    #expect(poller.blockingStatuses[idB] == .disabled(remainingSeconds: 120))
    #expect(poller.connectionStatuses[idA] == .connected)
    #expect(poller.connectionStatuses[idB] == .connected)
  }

  @Test("nil blocking status marks server disconnected")
  func nilBlockingStatusMarksDisconnected() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getBlockingStatusStub = [id: nil]
    let poller = makePoller()
    poller.startPolling()

    await scheduler.fireTick()

    #expect(poller.connectionStatuses[id] == .disconnected)
    #expect(poller.blockingStatuses[id] == nil)
  }

  @Test("getQuerySummary populates query summaries")
  func getQuerySummaryPopulatesQuerySummaries() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getQuerySummaryStub = [id: QuerySummary(totalQueries: 100, totalBlocked: 5)]
    let poller = makePoller()
    poller.startPolling()

    await scheduler.fireTick()

    #expect(poller.querySummaries[id]?.totalQueries == 100)
    #expect(poller.querySummaries[id]?.totalBlocked == 5)
  }

  @Test("nil query summary removes entry")
  func nilQuerySummaryRemovesEntry() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getQuerySummaryStub = [id: nil]
    let poller = makePoller()
    poller.startPolling()

    await scheduler.fireTick()

    #expect(poller.querySummaries[id] == nil)
  }

  // MARK: - applyBlockingChange()

  @Test("applyBlockingChange success reflects state immediately")
  func applyBlockingChangeSuccessReflectsState() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.setBlockingStub = [id: true]
    let poller = makePoller()

    await poller.applyBlockingChange(enabled: true, duration: nil)

    #expect(mockManager.setBlockingCallCount == 1)
    #expect(mockManager.setBlockingLastEnabled == true)
    #expect(mockManager.setBlockingLastDuration == nil)
    #expect(poller.blockingStatuses[id] == .enabled)
    #expect(poller.connectionStatuses[id] == .connected)
  }

  @Test("applyBlockingChange success with duration produces disabled(remainingSeconds:)")
  func applyBlockingChangeSuccessWithDuration() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.setBlockingStub = [id: true]
    let poller = makePoller()

    await poller.applyBlockingChange(enabled: false, duration: 300)

    #expect(poller.blockingStatuses[id] == .disabled(remainingSeconds: 300))
    #expect(poller.connectionStatuses[id] == .connected)
  }

  @Test("applyBlockingChange failure marks disconnected")
  func applyBlockingChangeFailureMarksDisconnected() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.setBlockingStub = [id: false]
    let poller = makePoller()

    await poller.applyBlockingChange(enabled: true, duration: nil)

    #expect(poller.connectionStatuses[id] == .disconnected)
    #expect(poller.blockingStatuses[id] == nil)
  }

  // MARK: - Server Change Observation

  @Test("structural server change triggers poll")
  func structuralServerChangeTriggersPoll() async {
    let id = UUID()
    mockManager.getBlockingStatusStub = [id: .enabled]
    let poller = makePoller()  // servers empty at creation

    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]

    // Wait for the sink-triggered poll's observable effect, not the call count:
    // the count increments inside `getBlockingStatus()`, before the poll applies
    // the results to `blockingStatuses`.
    await waitUntil { poller.blockingStatuses[id] == .enabled }
    #expect(poller.servers.count == 1)
    #expect(poller.blockingStatuses[id] == .enabled)
  }

  @Test("non-structural change skips poll")
  func nonStructuralChangeSkipsPoll() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    let poller = makePoller()
    #expect(mockManager.getBlockingStatusCallCount == 0)

    // Label-only change: same id, url, and version.
    mockManager.servers = [ServerConfig(id: id, label: "Renamed", url: "http://a.local", version: .v6)]

    await settle()

    #expect(mockManager.getBlockingStatusCallCount == 0)
    #expect(poller.servers.first?.label == "Renamed")
  }

  @Test("structural change prunes stale statuses")
  func structuralChangePrunesStaleStatuses() async {
    let idA = UUID()
    let idB = UUID()
    mockManager.servers = [
      ServerConfig(id: idA, url: "http://a.local", version: .v6),
      ServerConfig(id: idB, url: "http://b.local", version: .v6)
    ]
    mockManager.getBlockingStatusStub = [idA: .enabled, idB: .enabled]
    mockManager.getQuerySummaryStub = [
      idA: QuerySummary(totalQueries: 1, totalBlocked: 0),
      idB: QuerySummary(totalQueries: 2, totalBlocked: 1)
    ]
    let poller = makePoller()
    poller.startPolling()
    await scheduler.fireTick()
    #expect(poller.connectionStatuses.count == 2)

    // Remove server B. Update the stubs FIRST so the sink-triggered poll cannot
    // re-populate B's entries; then remove the server.
    mockManager.getBlockingStatusStub = [idA: .enabled]
    mockManager.getQuerySummaryStub = [idA: QuerySummary(totalQueries: 1, totalBlocked: 0)]
    mockManager.servers = [ServerConfig(id: idA, url: "http://a.local", version: .v6)]

    await waitUntil { mockManager.getBlockingStatusCallCount >= 2 }
    #expect(poller.connectionStatuses[idB] == nil)
    #expect(poller.blockingStatuses[idB] == nil)
    #expect(poller.querySummaries[idB] == nil)
    #expect(poller.servers.count == 1)
  }

  // MARK: - Recent Blocked Refresh

  @Test("recent blocked fetch uses local client IP by default")
  func recentBlockedFetchesWithClientIP() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getRecentBlockedStub = .success(
      [BlockedDomain(domain: "ads.com", timestamp: Date(), fromClientIp: "192.168.1.67")]
    )
    mockNetwork.stubbedIP = "192.168.1.67"
    Defaults[.showAllClientsRecentBlocked(suite: testSuite)] = false
    let poller = makePoller()
    poller.startPolling()

    await scheduler.fireTick()

    #expect(mockManager.getRecentBlockedCallCount == 1)
    #expect(mockManager.getRecentBlockedLastClientIp == "192.168.1.67")
    #expect(poller.recentBlocked.count == 1)
  }

  @Test("recent blocked fetch uses nil client when showAllClientsRecentBlocked is on")
  func recentBlockedFetchesWithNilClient() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getRecentBlockedStub = .success([])
    mockNetwork.stubbedIP = "192.168.1.67"
    Defaults[.showAllClientsRecentBlocked(suite: testSuite)] = true
    let poller = makePoller()
    poller.startPolling()

    await scheduler.fireTick()

    #expect(mockManager.getRecentBlockedCallCount == 1)
    #expect(mockManager.getRecentBlockedLastClientIp == nil)
  }

  @Test("recent blocked fetch errors are swallowed")
  func recentBlockedErrorDoesNotThrow() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getRecentBlockedStub = .failure(PiholeError.unknown("boom"))
    let poller = makePoller()
    poller.startPolling()

    await scheduler.fireTick()  // must complete; performPoll swallows the error

    #expect(poller.recentBlocked.isEmpty)
  }
}
