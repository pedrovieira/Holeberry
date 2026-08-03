import Defaults
import Foundation
import Testing

@testable import HoleberryCore

// swiftlint:disable type_name

@MainActor
@Suite("TemporaryUnblockPiholeServiceDecorator")
struct TemporaryUnblockPiholeServiceDecoratorTests {
  private func makeDecorator(
    service: any PiholeServiceInternal,
    suite: UserDefaults = TestDefaults.makeSuite()
  ) -> TemporaryUnblockPiholeServiceDecorator {
    TemporaryUnblockPiholeServiceDecorator(service: service, defaultsSuite: suite) { _ in }
  }

  // MARK: - unblockDomain (temporary)

  @Test("Temporary unblock adds tracking comment")
  func unblockDomainAddsTrackingComment() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(
      DomainEntry(id: 42, domain: "doubleclick.net", type: 0, comment: "via holeberryapp.com / test-uuid")
    )
    let decorator = makeDecorator(service: mock)

    try await decorator.unblockDomain("doubleclick.net", duration: 300)

    #expect(mock.addDomainCallCount == 1, "Should call addDomain on wrapped service")
    #expect(mock.addDomainLastDomain == "doubleclick.net")
    #expect(mock.addDomainLastList == .allow)
    #expect(
      mock.addDomainLastComment?.hasPrefix("via holeberryapp.com / ") ?? false,
      "Comment should have holeberryapp prefix"
    )
  }

  // MARK: - unblockDomain (permanent)

  @Test("Permanent unblock has standard comment")
  func unblockDomainPermanentNoTracking() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(
      DomainEntry(id: 1, domain: "permanent.com", type: 0, comment: nil)
    )
    let decorator = makeDecorator(service: mock)

    try await decorator.unblockDomain("permanent.com", duration: nil)

    #expect(mock.addDomainCallCount == 1)
    #expect(mock.addDomainLastComment == "via holeberryapp.com", "Permanent unblock should have standard comment")
  }

  // MARK: - Auto-expiry

  @Test("Auto-expiry removes record")
  func autoExpiryRemovesRecord() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(
      DomainEntry(id: 42, domain: "test.com", type: 0, comment: "via holeberryapp.com / uuid-1")
    )
    mock.deleteDomainByNameStub = .success(())

    let decorator = makeDecorator(service: mock)
    // Let init reconciliation finish
    try await Task.sleep(for: .milliseconds(100))
    try await decorator.unblockDomain("test.com", duration: 0.5)

    // Wait for expiry
    try await Task.sleep(for: .milliseconds(50))
    #expect(mock.deleteDomainByNameCallCount == 1, "Should delete domain after expiry")
  }

  @Test("Auto-expiry failure marks pending")
  func autoExpiryFailureMarksPending() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(
      DomainEntry(id: 42, domain: "test.com", type: 0, comment: "via holeberryapp.com / uuid-1")
    )
    mock.deleteDomainByNameStub = .failure(PiholeError.server(500, "Overloaded"))

    // Use a long sleep so the retry (which has backoff) doesn't fire during the test
    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: mock,
      defaultsSuite: TestDefaults.makeSuite()
    ) { _ in try await Task.sleep(for: .milliseconds(60000)) }
    // Let init reconciliation finish
    try await Task.sleep(for: .milliseconds(100))
    try await decorator.unblockDomain("test.com", duration: 0.5)

    try await Task.sleep(for: .milliseconds(50))
    #expect(mock.deleteDomainByNameCallCount == 1)
  }

  // MARK: - Passthrough

  @Test("addDomain passes through")
  func addDomainPassesThrough() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(
      DomainEntry(id: 1, domain: "passthrough.com", type: 0, comment: nil)
    )
    let decorator = makeDecorator(service: mock)

    _ = try await decorator.addDomain("passthrough.com", to: .allow)

    #expect(mock.addDomainCallCount == 1)
    #expect(mock.addDomainLastComment == nil)
  }

  @Test("deleteDomain passes through")
  func deleteDomainPassesThrough() async throws {
    let mock = MockPiholeService()
    mock.deleteDomainByNameStub = .success(())
    let decorator = makeDecorator(service: mock)

    try await decorator.deleteDomain(domain: "test.com")

    #expect(mock.deleteDomainByNameCallCount == 1)
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

  @Test("getDomains passes through")
  func getDomainsPassesThrough() async throws {
    let mock = MockPiholeService()
    mock.getDomainsStub = .success([DomainEntry(id: 1, domain: "test.com", type: 0, comment: nil)])
    let decorator = makeDecorator(service: mock)

    let domains = try await decorator.getDomains()

    #expect(mock.getDomainsCallCount == 1)
    #expect(domains.count == 1)
    #expect(domains[0].domain == "test.com")
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
    mock.deleteDomainByNameStub = .success(())

    let suite = TestDefaults.makeSuite()
    let record = TempUnblockRecord(
      domain: "tracker.com",
      uuid: "uuid-1",
      startDateUTC: Date(),
      durationSeconds: 0.5
    )
    prepopulate(suite: suite, serviceId: mock.id, records: [record])

    let decorator = makeDecorator(service: mock, suite: suite)
    // Let init reconciliation finish; expiry fires immediately (sleep is mocked)
    try await Task.sleep(for: .milliseconds(100))

    #expect(mock.getDomainsCallCount == 1, "Reconciliation should fetch domains")
    #expect(mock.deleteDomainByNameCallCount == 1, "Kept record should be expired")
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
    try await Task.sleep(for: .milliseconds(100))

    // Stale record should be removed by reconciliation
    let persisted = Defaults[.tempUnblocks(for: mock.id, suite: suite)]
    #expect(persisted.isEmpty, "Stale record should be removed during reconciliation")
    #expect(mock.getDomainsCallCount == 1, "Should have fetched domains for reconciliation")
    // No expiry should fire since record was removed
    #expect(mock.deleteDomainByNameCallCount == 0)
  }

  @Test("Reconciliation: server unreachable → expiry task started anyway")
  func reconcileServerUnreachable() async throws {
    let mock = MockPiholeService()
    mock.getDomainsStub = .failure(PiholeError.server(500, "Down"))
    mock.deleteDomainByNameStub = .success(())

    let suite = TestDefaults.makeSuite()
    let record = TempUnblockRecord(
      domain: "tracker.com",
      uuid: "uuid-3",
      startDateUTC: Date(),
      durationSeconds: 0.5
    )
    prepopulate(suite: suite, serviceId: mock.id, records: [record])

    let decorator = makeDecorator(service: mock, suite: suite)
    try await Task.sleep(for: .milliseconds(100))

    #expect(mock.getDomainsCallCount == 1, "Reconciliation should try to fetch domains")
    #expect(mock.deleteDomainByNameCallCount == 1, "Fallback expiry should delete domain")
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
    try await Task.sleep(for: .milliseconds(100))

    // Reconciliation ran, then expiry cleaned up the surviving record
    #expect(mock.getDomainsCallCount == 1, "Reconciliation should fetch domains")
    #expect(mock.deleteDomainByNameCallCount == 1, "Kept record should be expired")
    let persisted = Defaults[.tempUnblocks(for: mock.id, suite: suite)]
    #expect(persisted.isEmpty, "All records should be removed (stale filtered, matching expired)")
  }
}
