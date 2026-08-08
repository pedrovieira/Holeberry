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
    mockManager.getBlockingStatusStub = [id: .success(.enabled)]
    let poller = makePoller()

    poller.startPolling()

    #expect(scheduler.startCount == 1)
    #expect(scheduler.lastInterval == 3600)

    await scheduler.fireTick()

    #expect(mockManager.getBlockingStatusCallCount == 1)
    #expect(poller.connectionStatuses[id] == .connected)
    #expect(poller.blockingStatuses[id] == .enabled)
  }

  @Test("single failure does not flip the row (hysteresis)")
  func singleFailureDoesNotFlipRow() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getBlockingStatusStub = [id: .success(.enabled)]
    let poller = makePoller()
    poller.startPolling()
    await scheduler.fireTick()
    #expect(poller.connectionStates[id] == .healthy)

    mockManager.getBlockingStatusStub = [id: .failure(.network("blip"))]
    await scheduler.fireTick()
    #expect(poller.connectionStates[id] == .healthy, "first failure must not flip")
    #expect(poller.connectionStatuses[id] == .connected, "menu follows the row state")
  }

  @Test("two consecutive failures flip to classified error")
  func twoConsecutiveFailuresFlip() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getBlockingStatusStub = [id: .success(.enabled)]
    let poller = makePoller()
    poller.startPolling()
    await scheduler.fireTick()

    mockManager.getBlockingStatusStub = [id: .failure(.invalidCredentials)]
    await scheduler.fireTick()
    await scheduler.fireTick()

    #expect(poller.connectionStates[id] == .authError(reason: .passwordMayHaveChanged))
    #expect(poller.connectionStatuses[id] == .disconnected)
    #expect(poller.blockingStatuses[id] == nil)
  }

  @Test("unreachable classification carries lastSeen; instant recovery on success")
  func unreachableCarriesLastSeenAndRecoversInstantly() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getBlockingStatusStub = [id: .success(.enabled)]
    let poller = makePoller()
    poller.startPolling()
    await scheduler.fireTick()

    mockManager.getBlockingStatusStub = [id: .failure(.network("down"))]
    await scheduler.fireTick()
    await scheduler.fireTick()
    let lastSeen = poller.connectionStates[id]
    guard case .unreachable(let date)? = lastSeen else {
      Issue.record("expected unreachable, got \(String(describing: lastSeen))")
      return
    }
    #expect(date != nil)

    mockManager.getBlockingStatusStub = [id: .success(.enabled)]
    await scheduler.fireTick()
    #expect(poller.connectionStates[id] == .healthy)
  }

  @Test("failed blocking toggle counts as failure #1; success resets")
  func failedToggleCountsAsFirstFailure() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getBlockingStatusStub = [id: .success(.enabled)]
    let poller = makePoller()
    poller.startPolling()
    await scheduler.fireTick()

    // Toggle fails: menu flips red immediately, row stays healthy (failure #1)
    mockManager.setBlockingStub = [id: false]
    let results = await poller.applyBlockingChange(enabled: false, duration: nil)
    #expect(results[id] == false)
    #expect(poller.connectionStatuses[id] == .disconnected)
    #expect(poller.connectionStates[id] == .healthy)

    // Next poll also fails → row flips
    mockManager.getBlockingStatusStub = [id: .failure(.network("down"))]
    await scheduler.fireTick()
    guard case .unreachable? = poller.connectionStates[id] else {
      Issue.record("expected unreachable after toggle failure + poll failure")
      return
    }
  }

  @Test("successful blocking toggle resets row to healthy")
  func successfulToggleResetsRow() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getBlockingStatusStub = [id: .failure(.network("down"))]
    let poller = makePoller()
    poller.startPolling()
    await scheduler.fireTick()
    await scheduler.fireTick()
    guard case .unreachable? = poller.connectionStates[id] else {
      Issue.record("expected unreachable before toggle")
      return
    }

    mockManager.setBlockingStub = [id: true]
    let results = await poller.applyBlockingChange(enabled: true, duration: nil)
    #expect(results[id] == true)
    #expect(poller.connectionStates[id] == .healthy)
    #expect(poller.connectionStatuses[id] == .connected)
  }

  @Test("no state entry before the first poll")
  func noEntryBeforeFirstPoll() {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    let poller = makePoller()
    #expect(poller.connectionStates[id] == nil)
  }

  @Test("startPolling while running is a no-op; stopPolling allows restart")
  func startPollingIdempotentAndRestartable() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getBlockingStatusStub = [id: .success(.enabled)]
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
    mockManager.getBlockingStatusStub = [id: .success(.enabled)]
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
    mockManager.getBlockingStatusStub = [id: .success(.enabled)]
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
    mockManager.getBlockingStatusStub = [id: .success(.enabled)]
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
    mockManager.getBlockingStatusStub = [idA: .success(.enabled), idB: .success(.disabled(remainingSeconds: 120))]
    let poller = makePoller()
    poller.startPolling()

    await scheduler.fireTick()

    #expect(poller.blockingStatuses[idA] == .enabled)
    #expect(poller.blockingStatuses[idB] == .disabled(remainingSeconds: 120))
    #expect(poller.connectionStatuses[idA] == .connected)
    #expect(poller.connectionStatuses[idB] == .connected)
  }

  @Test("failed check marks server disconnected after hysteresis threshold")
  func failedCheckMarksDisconnectedAfterHysteresis() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getBlockingStatusStub = [id: .failure(.network("test"))]
    let poller = makePoller()
    poller.startPolling()

    // First failure: no row state yet, no menu flip.
    await scheduler.fireTick()
    #expect(poller.connectionStates[id] == nil)
    #expect(poller.connectionStatuses[id] == nil)

    // Second consecutive failure: row enters unreachable, menu follows.
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

  @Test("applyBlockingChange owns the countdown pill")
  func applyBlockingChangeOwnsCountdownPill() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.setBlockingStub = [id: true]

    let timer = TimerManager()
    let poller = ServerStatusPoller(
      manager: mockManager,
      networkInterface: mockNetwork,
      pollingInterval: 3600,
      defaultsSuite: testSuite,
      scheduler: scheduler,
      timerManager: timer
    )

    // Time-boxed disable starts the countdown pill...
    await poller.applyBlockingChange(enabled: false, duration: 300)
    #expect(timer.isRunning == true)
    #expect(timer.totalDuration == 300)

    // ...re-enable cancels it.
    await poller.applyBlockingChange(enabled: true, duration: nil)
    #expect(timer.isRunning == false)
  }

  // MARK: - Auto Re-enable Detection

  @Test("poll-observed disabled→enabled fires onBlockingAutoReenabled")
  func pollObservedReenableFiresCallback() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getBlockingStatusStub = [id: .success(.disabled(remainingSeconds: 300))]
    let poller = makePoller()
    var firedIDs: Set<UUID>?
    poller.onBlockingAutoReenabled = { firedIDs = $0 }
    poller.startPolling()

    await scheduler.fireTick()
    #expect(firedIDs == nil)

    mockManager.getBlockingStatusStub = [id: .success(.enabled)]
    await scheduler.fireTick()

    #expect(firedIDs == [id])
  }

  @Test("manual re-enable through applyBlockingChange never fires")
  func manualReenableDoesNotFire() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.setBlockingStub = [id: true]
    mockManager.getBlockingStatusStub = [id: .success(.disabled(remainingSeconds: 300))]
    let poller = makePoller()
    var fired = false
    poller.onBlockingAutoReenabled = { _ in fired = true }
    poller.startPolling()

    // Unblock via the funnel, then the user re-enables manually...
    await poller.applyBlockingChange(enabled: false, duration: 300)
    await scheduler.fireTick()
    #expect(fired == false)

    await poller.applyBlockingChange(enabled: true, duration: nil)
    // ...so even when the server reports enabled, the local reflection
    // already happened and no transition is observed.
    mockManager.getBlockingStatusStub = [id: .success(.enabled)]
    await scheduler.fireTick()

    #expect(fired == false)
  }

  @Test("fires only when the last disabled server re-enables")
  func firesWhenLastDisabledServerReenables() async {
    let idA = UUID()
    let idB = UUID()
    mockManager.servers = [
      ServerConfig(id: idA, url: "http://a.local", version: .v6),
      ServerConfig(id: idB, url: "http://b.local", version: .v6)
    ]
    mockManager.getBlockingStatusStub = [
      idA: .success(.disabled(remainingSeconds: 300)),
      idB: .success(.disabled(remainingSeconds: 300))
    ]
    let poller = makePoller()
    var firedIDs: Set<UUID>?
    poller.onBlockingAutoReenabled = { firedIDs = $0 }
    poller.startPolling()

    await scheduler.fireTick()
    #expect(firedIDs == nil)

    // One server re-enables; the unblock is still active on the other.
    mockManager.getBlockingStatusStub = [idA: .success(.enabled), idB: .success(.disabled(remainingSeconds: 60))]
    await scheduler.fireTick()
    #expect(firedIDs == nil)

    // The last one re-enables → exactly one event.
    mockManager.getBlockingStatusStub = [idA: .success(.enabled), idB: .success(.enabled)]
    await scheduler.fireTick()
    #expect(firedIDs == [idB])
  }

  @Test("failed manual re-enable does not fire when a later poll sees enabled")
  func failedManualReenableDoesNotFire() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.setBlockingStub = [id: true]
    mockManager.getBlockingStatusStub = [id: .success(.disabled(remainingSeconds: 300))]
    let poller = makePoller()
    var fired = false
    poller.onBlockingAutoReenabled = { _ in fired = true }

    await poller.applyBlockingChange(enabled: false, duration: 300)

    // The manual re-enable attempt fails: local state is dropped, so the
    // poll observing `.enabled` is not a disabled→enabled transition.
    mockManager.setBlockingStub = [id: false]
    await poller.applyBlockingChange(enabled: true, duration: nil)

    poller.startPolling()
    mockManager.getBlockingStatusStub = [id: .success(.enabled)]
    await scheduler.fireTick()

    #expect(fired == false)
  }

  @Test("manual re-enable mid-fetch suppresses the auto-reenable event")
  func manualReenableMidFetchDoesNotFire() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.setBlockingStub = [id: true]
    mockManager.getBlockingStatusStub = [id: .success(.disabled(remainingSeconds: 300))]
    var resumeGate: (() -> Void)?
    mockManager.getBlockingStatusGate = {
      await withCheckedContinuation { continuation in
        resumeGate = { continuation.resume() }
      }
    }
    let poller = makePoller()
    var fired = false
    poller.onBlockingAutoReenabled = { _ in fired = true }
    poller.startPolling()

    // Poll #1: snapshots .disabled, then the status fetch is held open.
    let tickTask = Task { await scheduler.fireTick() }
    await waitUntil { mockManager.getBlockingStatusCallCount == 1 }

    // The user re-enables while the fetch is in flight.
    await poller.applyBlockingChange(enabled: true, duration: nil)

    // The stale fetch completes: its results must be discarded, no event.
    mockManager.getBlockingStatusStub = [id: .success(.enabled)]
    resumeGate?()
    await tickTask.value

    #expect(fired == false)
    #expect(poller.blockingStatuses[id] == .enabled)
  }

  // MARK: - Server Change Observation

  @Test("structural server change triggers poll")
  func structuralServerChangeTriggersPoll() async {
    let id = UUID()
    mockManager.getBlockingStatusStub = [id: .success(.enabled)]
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
    mockManager.getBlockingStatusStub = [idA: .success(.enabled), idB: .success(.enabled)]
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
    mockManager.getBlockingStatusStub = [idA: .success(.enabled)]
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

  // MARK: - Timer Expiry

  /// Poller wired to a real (injectable) `TimerManager`, like the composition root.
  private func makePollerWithTimer(
    _ timer: TimerManager,
    sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
  ) -> ServerStatusPoller {
    ServerStatusPoller(
      manager: mockManager,
      networkInterface: mockNetwork,
      pollingInterval: 3600,
      defaultsSuite: testSuite,
      scheduler: scheduler,
      timerManager: timer,
      sleep: sleep
    )
  }

  @Test("timer expiry triggers a status-only refresh and fires onBlockingAutoReenabled")
  func timerExpiryTriggersStatusOnlyRefresh() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.setBlockingStub = [id: true]
    mockManager.getBlockingStatusStub = [id: .success(.disabled(remainingSeconds: 300))]
    let timer = TimerManager()
    let poller = makePollerWithTimer(timer)
    var firedIDs: Set<UUID>?
    poller.onBlockingAutoReenabled = { firedIDs = $0 }

    // Time-boxed disable with an already-expired duration; the next tick must
    // re-check status immediately.
    await poller.applyBlockingChange(enabled: false, duration: 0)
    mockManager.getBlockingStatusStub = [id: .success(.enabled)]

    timer.countdownTick()

    await waitUntil { firedIDs == [id] }
    #expect(timer.isRunning == false)
    // Status-only: no query summary or recent-blocked fetches.
    #expect(mockManager.getQuerySummaryCallCount == 0)
    #expect(mockManager.getRecentBlockedCallCount == 0)
  }

  @Test("manual re-enable cancels the timer without a status refresh")
  func manualReenableCancelDoesNotRefresh() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.setBlockingStub = [id: true]
    mockManager.getBlockingStatusStub = [id: .success(.disabled(remainingSeconds: 300))]
    let timer = TimerManager()
    let poller = makePollerWithTimer(timer)

    await poller.applyBlockingChange(enabled: false, duration: 0)
    await poller.applyBlockingChange(enabled: true, duration: nil)

    await settle()
    #expect(timer.isRunning == false)
    #expect(mockManager.getBlockingStatusCallCount == 0)
  }

  @Test("timer expiry during an in-flight poll does not double-fetch")
  func timerExpiryDuringInFlightPollSkipsRefresh() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.setBlockingStub = [id: true]
    mockManager.getBlockingStatusStub = [id: .success(.disabled(remainingSeconds: 300))]
    // Arm the gate before the timer starts so any stray re-check suspends here.
    var resumeGate: (() -> Void)?
    mockManager.getBlockingStatusGate = {
      await withCheckedContinuation { continuation in
        resumeGate = { continuation.resume() }
      }
    }
    let timer = TimerManager()
    let poller = makePollerWithTimer(timer)
    var firedIDs: Set<UUID>?
    poller.onBlockingAutoReenabled = { firedIDs = $0 }
    await poller.applyBlockingChange(enabled: false, duration: 0)

    // Expire the countdown while the poll's status fetch is held open: the
    // re-check must skip so the event fires exactly once.
    mockManager.getBlockingStatusStub = [id: .success(.enabled)]
    poller.startPolling()
    let tickTask = Task { await scheduler.fireTick() }
    await waitUntil { mockManager.getBlockingStatusCallCount == 1 }

    timer.countdownTick()
    await settle()

    resumeGate?()
    await tickTask.value

    #expect(firedIDs == [id])
    #expect(mockManager.getBlockingStatusCallCount == 1)
  }

  @Test("poll observing a server-side disable starts the countdown from its remaining")
  func pollStartsCountdownFromServerRemaining() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getBlockingStatusStub = [id: .success(.disabled(remainingSeconds: 300))]
    let timer = TimerManager()
    let poller = makePollerWithTimer(timer)
    poller.startPolling()

    await scheduler.fireTick()

    #expect(timer.isRunning)
    #expect(timer.totalDuration == 300)
  }

  @Test("poll does not restart a running countdown")
  func pollDoesNotRestartRunningCountdown() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.setBlockingStub = [id: true]
    mockManager.getBlockingStatusStub = [id: .success(.disabled(remainingSeconds: 999))]
    let timer = TimerManager()
    let poller = makePollerWithTimer(timer)
    await poller.applyBlockingChange(enabled: false, duration: 300)

    poller.startPolling()
    await scheduler.fireTick()

    #expect(timer.isRunning)
    #expect(timer.totalDuration == 300)
  }

  @Test("timer expiry re-checks again while the server is still disabled")
  func timerExpiryRetriesWhileStillDisabled() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.setBlockingStub = [id: true]
    mockManager.getBlockingStatusStub = [id: .success(.disabled(remainingSeconds: 3))]
    var resumeSleep: (() -> Void)?
    let timer = TimerManager()
    let poller = makePollerWithTimer(timer) { _ in
      await withCheckedContinuation { continuation in
        resumeSleep = { continuation.resume() }
      }
    }
    var firedIDs: Set<UUID>?
    poller.onBlockingAutoReenabled = { firedIDs = $0 }

    await poller.applyBlockingChange(enabled: false, duration: 0)
    timer.countdownTick()  // expires → re-check #1 → still disabled → waits

    await waitUntil { resumeSleep != nil }
    mockManager.getBlockingStatusStub = [id: .success(.enabled)]
    resumeSleep?()

    await waitUntil { firedIDs == [id] }
    #expect(mockManager.getBlockingStatusCallCount == 2)
    #expect(timer.isRunning == false)
  }

  @Test("auto-reenable cancels a still-running countdown")
  func autoReenableCancelsRunningCountdown() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.setBlockingStub = [id: true]
    mockManager.getBlockingStatusStub = [id: .success(.disabled(remainingSeconds: 300))]
    let timer = TimerManager()
    let poller = makePollerWithTimer(timer)
    await poller.applyBlockingChange(enabled: false, duration: 300)

    // The server re-enabled externally; the next poll observes the transition.
    mockManager.getBlockingStatusStub = [id: .success(.enabled)]
    poller.startPolling()
    await scheduler.fireTick()

    #expect(timer.isRunning == false)
  }

  @Test("expired countdown re-arms from the server remaining when still disabled")
  func timerExpiryReArmsWhenServerStillDisabled() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.setBlockingStub = [id: true]
    mockManager.getBlockingStatusStub = [id: .success(.disabled(remainingSeconds: 60))]
    let timer = TimerManager()
    let poller = makePollerWithTimer(timer) { _ in }
    var fired = false
    poller.onBlockingAutoReenabled = { _ in fired = true }

    await poller.applyBlockingChange(enabled: false, duration: 0)
    timer.countdownTick()  // expires → re-check → server still disabled(60)

    await waitUntil { timer.isRunning }
    #expect(timer.totalDuration == 60)
    #expect(fired == false)
  }

  @Test("expired countdown does not re-arm for near-zero remaining")
  func timerExpiryDoesNotReArmForTinyRemaining() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.setBlockingStub = [id: true]
    mockManager.getBlockingStatusStub = [id: .success(.disabled(remainingSeconds: 3))]
    let timer = TimerManager()
    let poller = makePollerWithTimer(timer) { _ in }

    await poller.applyBlockingChange(enabled: false, duration: 0)
    timer.countdownTick()  // expires → re-check → server still disabled(3)

    await settle()
    #expect(timer.isRunning == false)
  }

  @Test("poll does not start a countdown for indefinite disables")
  func pollDoesNotStartCountdownForIndefiniteDisable() async {
    let id = UUID()
    mockManager.servers = [ServerConfig(id: id, url: "http://a.local", version: .v6)]
    mockManager.getBlockingStatusStub = [id: .success(.disabled(remainingSeconds: nil))]
    let timer = TimerManager()
    let poller = makePollerWithTimer(timer)
    poller.startPolling()

    await scheduler.fireTick()

    #expect(timer.isRunning == false)
  }
}
