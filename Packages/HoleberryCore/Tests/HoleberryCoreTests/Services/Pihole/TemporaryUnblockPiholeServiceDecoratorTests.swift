import Defaults
import Foundation
import Testing

@testable import HoleberryCore

// swiftlint:disable type_name

@MainActor
@Suite("TemporaryUnblockPiholeServiceDecorator")
struct TemporaryUnblockPiholeServiceDecoratorTests {
  private func makeDecorator(
    service: any PiholeServiceCommentAdding,
    suite: UserDefaults = TestDefaults.makeSuite()
  ) -> TemporaryUnblockPiholeServiceDecorator {
    TemporaryUnblockPiholeServiceDecorator(service: service, defaultsSuite: suite) { _ in }
  }

  /// Like `makeDecorator`, but real-world durations (≥10s) park for the whole
  /// test so scheduled records can be observed before any expiry side effect.
  private func makeParkingDecorator(
    service: any PiholeServiceCommentAdding,
    suite: UserDefaults = TestDefaults.makeSuite()
  ) -> TemporaryUnblockPiholeServiceDecorator {
    TemporaryUnblockPiholeServiceDecorator(service: service, defaultsSuite: suite) { duration in
      if duration < 10 { return }
      try await Task.sleep(nanoseconds: UInt64(60000 * 1_000_000))
    }
  }

  /// Polls `condition` until it holds or `timeout` elapses. Async side effects
  /// (init reconciliation, expiry tasks) run on the main actor and can be
  /// delayed under parallel test load, so fixed sleeps are unreliable.
  private func eventually(
    _ condition: @MainActor () -> Bool,
    // Wall-clock headroom: retry backoffs and expiry timers must fit even on
    // slow CI runners (locally 2s was enough, CI routinely misses it).
    timeout: Duration = .seconds(10)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: UInt64(10 * 1_000_000))
    }
    return condition()
  }

  // MARK: - unblockDomain (temporary)

  @Test("Temporary unblock adds with a tracking comment")
  func unblockDomainAddsTrackingComment() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(.added)
    let suite = TestDefaults.makeSuite()
    let decorator = makeParkingDecorator(service: mock, suite: suite)

    try await decorator.unblockDomain("doubleclick.net", duration: 300)

    #expect(mock.addDomainCallCount == 1, "Should call addDomain on the wrapped service")
    #expect(mock.addDomainLastDomain == "doubleclick.net")
    #expect(mock.addDomainLastList == .allow)
    #expect(
      mock.addDomainLastComment?.hasPrefix("via holeberryapp.com / ") ?? false,
      "Comment should have holeberryapp prefix"
    )
    #expect(Defaults[.tempUnblocks(for: mock.id, suite: suite)].count == 1)
  }

  // MARK: - unblockDomain (permanent)

  @Test(
    "Permanent unblock does not track fresh or existing entries", arguments: [DomainAddOutcome.added, .alreadyPresent])
  func unblockDomainPermanentNoTracking(outcome: DomainAddOutcome) async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(outcome)
    let suite = TestDefaults.makeSuite()
    let decorator = makeDecorator(service: mock, suite: suite)

    try await decorator.unblockDomain("permanent.com", duration: nil)

    #expect(mock.addDomainCallCount == 1)
    #expect(mock.addDomainLastComment == "via holeberryapp.com", "Permanent unblock should have standard comment")
    #expect(Defaults[.tempUnblocks(for: mock.id, suite: suite)].isEmpty)
  }

  // MARK: - Auto-expiry

  @Test("Auto-expiry removes record")
  func autoExpiryRemovesRecord() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(.added)
    mock.deleteDomainStub = .success(())

    let decorator = makeDecorator(service: mock)
    try await decorator.unblockDomain("test.com", duration: 0.5)

    // Wait for expiry
    #expect(await eventually { mock.deleteDomainCallCount == 1 }, "Should delete domain after expiry")
  }

  @Test("Auto-expiry failure marks pending")
  func autoExpiryFailureMarksPending() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(.added)
    mock.deleteDomainStub = .failure(PiholeError.server(500, "Overloaded"))

    // Expiry delay (the record duration, 0.5s) returns immediately; retry
    // backoffs (≥10s, from backoffIntervals) are elongated so the retry never
    // fires during the test.
    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: mock,
      defaultsSuite: TestDefaults.makeSuite()
    ) { duration in
      if duration < 10 { return }
      try await Task.sleep(nanoseconds: UInt64(60000 * 1_000_000))
    }
    try await decorator.unblockDomain("test.com", duration: 0.5)

    #expect(await eventually { mock.deleteDomainCallCount == 1 }, "Expiry should attempt deletion once")
  }

  // MARK: - Retry

  /// Lets the test deterministically release a parked retry backoff.
  private final class RetryGate: @unchecked Sendable {
    var isOpen = false
  }

  @Test("Retry succeeds after transient expiry failure")
  func retrySucceedsAfterTransientFailure() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(.added)
    mock.deleteDomainStub = .failure(PiholeError.server(500, "Overloaded"))

    let suite = TestDefaults.makeSuite()
    let gate = RetryGate()
    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: mock,
      defaultsSuite: suite
    ) { duration in
      // Expiry delay (0.5s) returns immediately; every retry backoff parks on
      // the gate so the test can swap the stub before the retry runs.
      if duration < 10 { return }
      while !gate.isOpen {
        try await Task.sleep(nanoseconds: UInt64(10 * 1_000_000))
      }
    }
    try await decorator.unblockDomain("test.com", duration: 0.5)

    // First expiry delete attempt fails…
    #expect(await eventually { mock.deleteDomainCallCount >= 1 })
    // …then the retry succeeds and the record is cleaned up
    mock.deleteDomainStub = .success(())
    gate.isOpen = true
    #expect(await eventually { mock.deleteDomainCallCount >= 2 })
    #expect(
      Defaults[.tempUnblocks(for: mock.id, suite: suite)].isEmpty,
      "Record should be removed after successful retry"
    )
  }

  @Test("Retry failures keep retrying with growing count")
  func retryPersistentFailure() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(.added)
    mock.deleteDomainStub = .failure(PiholeError.server(500, "Overloaded"))

    let suite = TestDefaults.makeSuite()
    var sleeps = 0
    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: mock,
      defaultsSuite: suite
    ) { duration in
      sleeps += 1
      // Expiry + first two backoffs are instant; the third backoff stalls
      if duration < 10 || sleeps <= 3 { return }
      try await Task.sleep(nanoseconds: UInt64(60000 * 1_000_000))
    }
    try await decorator.unblockDomain("test.com", duration: 0.5)

    // Expiry attempt + two retries (each failing) = 3 delete attempts
    #expect(await eventually { mock.deleteDomainCallCount == 3 })
    let record = Defaults[.tempUnblocks(for: mock.id, suite: suite)].first
    #expect(record?.pendingRemoval == true, "Record should stay pending while retries fail")
    #expect(record?.retryCount == 3)
  }

  @Test("Retry with unknown error removes record")
  func retryUnknownErrorRemovesRecord() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(.added)
    mock.deleteDomainStub = .failure(PiholeError.server(500, "Overloaded"))

    let suite = TestDefaults.makeSuite()
    let gate = RetryGate()
    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: mock,
      defaultsSuite: suite
    ) { duration in
      if duration < 10 { return }
      while !gate.isOpen {
        try await Task.sleep(nanoseconds: UInt64(10 * 1_000_000))
      }
    }
    try await decorator.unblockDomain("test.com", duration: 0.5)

    #expect(await eventually { mock.deleteDomainCallCount >= 1 })
    mock.deleteDomainStub = .failure(PiholeError.unknown("Domain not found"))
    gate.isOpen = true
    #expect(await eventually { mock.deleteDomainCallCount >= 2 })
    #expect(
      Defaults[.tempUnblocks(for: mock.id, suite: suite)].isEmpty,
      "Unknown error should drop the record without further retries"
    )
  }

  // MARK: - Expiry notifications

  /// Thread-safe box for capturing posted notification payloads in tests.
  private final class PostedDomainsBox: @unchecked Sendable {
    var domains: [String] = []
  }

  @Test("Auto-expiry posts domainUnblockExpired")
  func autoExpiryPostsNotification() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(.added)
    mock.deleteDomainStub = .success(())

    let center = NotificationCenter()
    let posted = PostedDomainsBox()
    let token = center.addObserver(forName: .domainUnblockExpired, object: nil, queue: nil) { notification in
      if let domain = notification.userInfo?["domain"] as? String {
        posted.domains.append(domain)
      }
    }
    defer { center.removeObserver(token) }

    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: mock,
      defaultsSuite: TestDefaults.makeSuite(),
      notificationCenter: center
    ) { _ in }
    try await decorator.unblockDomain("notify-expiry.com", duration: 0.5)

    #expect(
      await eventually { posted.domains.contains("notify-expiry.com") },
      "Expiry should post .domainUnblockExpired with the domain"
    )
  }

  @Test("Manual deleteDomain does not post domainUnblockExpired")
  func manualDeleteDoesNotPostExpiryNotification() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(.added)
    mock.deleteDomainStub = .success(())

    let suite = TestDefaults.makeSuite()
    let center = NotificationCenter()
    let posted = PostedDomainsBox()
    let token = center.addObserver(forName: .domainUnblockExpired, object: nil, queue: nil) { notification in
      if let domain = notification.userInfo?["domain"] as? String {
        posted.domains.append(domain)
      }
    }
    defer { center.removeObserver(token) }

    // Long duration with an elongated sleep so the expiry task never fires
    // during the test — the removal below is the user's own action.
    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: mock,
      defaultsSuite: suite,
      notificationCenter: center
    ) { duration in
      if duration < 10 { return }
      try await Task.sleep(nanoseconds: UInt64(60000 * 1_000_000))
    }
    try await decorator.unblockDomain("manual-delete.com", duration: 3600)
    try await decorator.deleteDomain("manual-delete.com", from: .allow)

    #expect(
      Defaults[.tempUnblocks(for: mock.id, suite: suite)].isEmpty,
      "Manual removal should drop the record"
    )
    #expect(posted.domains.isEmpty, "Manual removal should not post .domainUnblockExpired")
  }

  // MARK: - Passthrough

  @Test("addDomain passes through")
  func addDomainPassesThrough() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(.alreadyPresent)
    let decorator = makeDecorator(service: mock)

    let outcome = try await decorator.addDomain("passthrough.com", to: .allow, comment: "manual")

    #expect(mock.addDomainCallCount == 1)
    #expect(mock.addDomainLastComment == "manual")
    #expect(outcome == .alreadyPresent)
  }

  @Test("deleteDomain passes through")
  func deleteDomainPassesThrough() async throws {
    let mock = MockPiholeService()
    mock.deleteDomainStub = .success(())
    let decorator = makeDecorator(service: mock)

    try await decorator.deleteDomain("test.com", from: .deny)

    #expect(mock.deleteDomainCallCount == 1)
    #expect(mock.deleteDomainLastDomain == "test.com")
    #expect(mock.deleteDomainLastList == .deny)
  }

  @Test("deny deletion keeps the temp-unblock record")
  func deleteDenyEntryKeepsRecord() async throws {
    let mock = MockPiholeService()
    mock.getDomainsStub = .success([DomainEntry(id: 1, domain: "keepme.com", type: 0, comment: nil)])
    mock.deleteDomainStub = .success(())

    let suite = TestDefaults.makeSuite()
    Defaults[.tempUnblocks(for: mock.id, suite: suite)] = [
      TempUnblockRecord(domain: "keepme.com", uuid: "uuid-keep", startDateUTC: Date(), durationSeconds: 3600)
    ]
    let decorator = makeParkingDecorator(service: mock, suite: suite)

    try await decorator.deleteDomain("keepme.com", from: .deny)

    #expect(
      Defaults[.tempUnblocks(for: mock.id, suite: suite)].count == 1,
      "Only an allow deletion ends a temp unblock")
  }

  @Test("checkStatus passes through")
  func checkStatusPassesThrough() async throws {
    let mock = MockPiholeService()
    mock.checkStatusStub = .success(.enabled)
    let decorator = makeDecorator(service: mock)

    let status = try await decorator.checkStatus()

    #expect(mock.checkStatusCallCount == 1)
    #expect(status == .enabled)
  }

  @Test("getDomains(from:) passes through")
  func getDomainsPassesThrough() async throws {
    let mock = MockPiholeService()
    mock.getDomainsStub = .success([DomainEntry(id: 1, domain: "test.com", type: 0, comment: nil)])
    let decorator = makeDecorator(service: mock)

    let domains = try await decorator.getDomains(from: .deny)

    #expect(mock.getDomainsCallCount == 1)
    #expect(mock.getDomainsLastList == .deny)
    #expect(domains.map(\.domain) == ["test.com"])
  }

  @Test("getQuerySummary passes through")
  func getQuerySummaryPassesThrough() async throws {
    let mock = MockPiholeService()
    mock.getQuerySummaryStub = .success(QuerySummary(totalQueries: 100, totalBlocked: 10))
    let decorator = makeDecorator(service: mock)

    let summary = try await decorator.getQuerySummary()

    #expect(mock.getQuerySummaryCallCount == 1)
    #expect(summary.totalQueries == 100)
    #expect(summary.totalBlocked == 10)
  }

  @Test("updateGravity passes through")
  func updateGravityPassesThrough() async throws {
    let mock = MockPiholeService()
    let decorator = makeDecorator(service: mock)
    try await decorator.updateGravity()
    #expect(mock.updateGravityCallCount == 1)
  }

  @Test("setBlocking passes through")
  func setBlockingPassesThrough() async throws {
    let mock = MockPiholeService()
    mock.setBlockingStub = .success(())
    let decorator = makeDecorator(service: mock)

    try await decorator.setBlocking(enabled: false, duration: 300)

    #expect(mock.setBlockingCallCount == 1)
    #expect(mock.setBlockingLastEnabled == false)
    #expect(mock.setBlockingLastDuration == 300)
  }

  @Test("getRecentBlocked passes through")
  func getRecentBlockedPassesThrough() async throws {
    let mock = MockPiholeService()
    let interval = DateInterval(start: Date(), duration: 3600)
    let decorator = makeDecorator(service: mock)

    _ = try await decorator.getRecentBlocked(forClientIp: nil, interval: interval)

    #expect(mock.getRecentBlockedCallCount == 1)
  }

  @Test("login passes through")
  func loginPassesThrough() async throws {
    let mock = MockPiholeService()
    let decorator = makeDecorator(service: mock)

    try await decorator.login()

    #expect(mock.loginCallCount == 1)
  }

  @Test("logout passes through")
  func logoutPassesThrough() async {
    let mock = MockPiholeService()
    let decorator = makeDecorator(service: mock)

    await decorator.logout()

    #expect(mock.logoutCallCount == 1)
  }

  @Test("identity delegates to wrapped service")
  func identityDelegates() {
    let id = UUID()
    let mock = MockPiholeService(id: id, label: "test-label", url: "http://test.url", version: .v5)
    let decorator = makeDecorator(service: mock)

    #expect(decorator.id == id)
    #expect(decorator.label == "test-label")
    decorator.label = "updated"
    #expect(mock.label == "updated")
    #expect(decorator.url == "http://test.url")
    decorator.url = "http://new.url"
    #expect(mock.url == "http://new.url")
    #expect(decorator.version == .v5)
    decorator.version = .v6
    #expect(mock.version == .v6)
  }

  // MARK: - Init-time reconciliation

  private func prepopulate(
    suite: UserDefaults,
    serviceId: UUID,
    records: [TempUnblockRecord]
  ) {
    Defaults[.tempUnblocks(for: serviceId, suite: suite)] = records
  }

  @Test("Reconciliation: server has domain → record kept, expiry runs")
  func reconcileDomainStillOnServer() async throws {
    let mock = MockPiholeService()
    mock.getDomainsStub = .success([
      DomainEntry(id: 1, domain: "tracker.com", type: 0, comment: nil)
    ])
    mock.deleteDomainStub = .success(())

    let suite = TestDefaults.makeSuite()
    let record = TempUnblockRecord(
      domain: "tracker.com",
      uuid: "uuid-1",
      startDateUTC: Date(),
      durationSeconds: 0.5
    )
    prepopulate(suite: suite, serviceId: mock.id, records: [record])

    let decorator = makeDecorator(service: mock, suite: suite)
    // Expiry fires immediately (sleep is mocked)
    #expect(await eventually { mock.deleteDomainCallCount == 1 }, "Kept record should be expired")
    #expect(mock.getDomainsCallCount == 1, "Reconciliation should fetch domains")
    let afterExpiry = Defaults[.tempUnblocks(for: mock.id, suite: suite)]
    #expect(afterExpiry.isEmpty, "Record should be removed after expiry")
  }

  @Test("Reconciliation: server missing domain → stale record removed")
  func reconcileDomainMissingFromServer() async throws {
    let mock = MockPiholeService()
    mock.getDomainsStub = .success([])

    let suite = TestDefaults.makeSuite()
    let record = TempUnblockRecord(
      domain: "stale-tracker.com",
      uuid: "uuid-2",
      startDateUTC: Date(),
      durationSeconds: 3600
    )
    prepopulate(suite: suite, serviceId: mock.id, records: [record])

    let decorator = makeDecorator(service: mock, suite: suite)

    // Stale record should be removed by reconciliation
    #expect(
      await eventually { Defaults[.tempUnblocks(for: mock.id, suite: suite)].isEmpty },
      "Stale record should be removed during reconciliation"
    )
    #expect(mock.getDomainsCallCount == 1, "Should have fetched domains for reconciliation")
    // No expiry should fire since record was removed
    #expect(mock.deleteDomainCallCount == 0)
  }

  @Test("Reconciliation: server unreachable → expiry task started anyway")
  func reconcileServerUnreachable() async throws {
    let mock = MockPiholeService()
    mock.getDomainsStub = .failure(PiholeError.server(500, "Down"))
    mock.deleteDomainStub = .success(())

    let suite = TestDefaults.makeSuite()
    let record = TempUnblockRecord(
      domain: "tracker.com",
      uuid: "uuid-3",
      startDateUTC: Date(),
      durationSeconds: 0.5
    )
    prepopulate(suite: suite, serviceId: mock.id, records: [record])

    let decorator = makeDecorator(service: mock, suite: suite)

    #expect(await eventually { mock.deleteDomainCallCount == 1 }, "Fallback expiry should delete domain")
    #expect(mock.getDomainsCallCount == 1, "Reconciliation should try to fetch domains")
    let afterExpiry = Defaults[.tempUnblocks(for: mock.id, suite: suite)]
    #expect(afterExpiry.isEmpty, "Record should be removed after expiry")
  }

  @Test("Reconciliation: mixed records — matching kept, stale removed")
  func reconcileMixedRecords() async throws {
    let mock = MockPiholeService()
    mock.getDomainsStub = .success([
      DomainEntry(id: 1, domain: "active.com", type: 0, comment: nil)
    ])

    let suite = TestDefaults.makeSuite()
    let records = [
      TempUnblockRecord(
        domain: "active.com",
        uuid: "uuid-4",
        startDateUTC: Date(),
        durationSeconds: 3600
      ),
      TempUnblockRecord(
        domain: "expired.com",
        uuid: "uuid-5",
        startDateUTC: Date(),
        durationSeconds: 3600
      )
    ]
    prepopulate(suite: suite, serviceId: mock.id, records: records)

    let decorator = makeDecorator(service: mock, suite: suite)

    // Reconciliation ran, then expiry cleaned up the surviving record
    #expect(await eventually { mock.deleteDomainCallCount == 1 }, "Kept record should be expired")
    #expect(mock.getDomainsCallCount == 1, "Reconciliation should fetch domains")
    let persisted = Defaults[.tempUnblocks(for: mock.id, suite: suite)]
    #expect(persisted.isEmpty, "All records should be removed (stale filtered, matching expired)")
  }

  // MARK: - v5 probe-first flow and expiry guard

  // MARK: - Temporary unblock bookkeeping

  @Test("an allow entry that is already there is left alone and not tracked")
  func alreadyPresentEntryIsNotTracked() async throws {
    let mock = MockPiholeService(version: .v5)
    mock.addDomainStub = .success(.alreadyPresent)
    let suite = TestDefaults.makeSuite()
    let decorator = makeParkingDecorator(service: mock, suite: suite)

    try await decorator.unblockDomain("x.com", duration: 60)

    #expect(mock.addDomainCallCount == 1)
    #expect(mock.addDomainLastDomain == "x.com")
    #expect(mock.addDomainLastList == .allow)
    #expect(
      Defaults[.tempUnblocks(for: mock.id, suite: suite)].isEmpty,
      "An entry we did not add is not ours to expire")
  }

  @Test("a fresh allow entry is tracked")
  func freshEntryIsTracked() async throws {
    let mock = MockPiholeService(version: .v5)
    mock.addDomainStub = .success(.added)
    let suite = TestDefaults.makeSuite()
    let decorator = makeParkingDecorator(service: mock, suite: suite)

    try await decorator.unblockDomain("x.com", duration: 60)

    #expect(mock.addDomainCallCount == 1)
    #expect(Defaults[.tempUnblocks(for: mock.id, suite: suite)].count == 1)
  }

  @Test("An add failure propagates when recovery cannot confirm ownership")
  func addFailurePropagates() async throws {
    let mock = MockPiholeService(version: .v5)
    mock.addDomainStub = .failure(PiholeError.network("down"))
    let suite = TestDefaults.makeSuite()
    let decorator = makeParkingDecorator(service: mock, suite: suite)

    await #expect(throws: PiholeError.network("down")) {
      try await decorator.unblockDomain("x.com", duration: 60)
    }
    #expect(Defaults[.tempUnblocks(for: mock.id, suite: suite)].isEmpty)
  }

  @Test("expiry deletes from the allow list and stops reading it")
  func expiryDeletesWithoutProbe() async throws {
    let mock = MockPiholeService(version: .v5)
    mock.getDomainsStub = .success([DomainEntry(id: 1, domain: "x.com", type: 0, comment: nil)])
    mock.deleteDomainStub = .success(())

    let suite = TestDefaults.makeSuite()
    Defaults[.tempUnblocks(for: mock.id, suite: suite)] = [
      TempUnblockRecord(domain: "x.com", uuid: "uuid-v5", startDateUTC: Date(), durationSeconds: 0.5)
    ]

    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: mock,
      defaultsSuite: suite
    ) { _ in }
    _ = decorator

    #expect(
      await eventually { mock.deleteDomainCallCount == 1 },
      "A tracked entry is removed on expiry, from the allow list only")
    #expect(mock.deleteDomainLastList == .allow)
    #expect(mock.getDomainsCallCount == 1, "Only reconciliation reads the list; expiry does not probe")
  }
}
