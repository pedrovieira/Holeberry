import Defaults
import Foundation
import Testing

@testable import HoleberryCore

// swiftlint:disable type_name

@MainActor
@Suite("Temporary unblock ownership")
struct TempUnblockOwnershipTests {

  // Fixed ownership UUIDs so tests can build the decorator's comment tokens.
  private static let t1 = UUID()
  private static let t2 = UUID()
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

  private final class PostedDomainsBox: @unchecked Sendable {
    var domains: [String] = []
  }

  @Test("v6 duplicate with a foreign entry reports an existing enabled entry and schedules nothing")
  func v6DuplicateForeign() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(.alreadyPresent)
    mock.getDomainStub = .success(DomainEntry(id: 9, domain: "x.com", type: 0, comment: "user", enabled: true))
    let decorator = makeDecorator(service: mock)
    let outcome = try await decorator.unblockDomain(
      "x.com", duration: 300, ownershipID: Self.t1)
    #expect(outcome == .alreadyPresent(enabled: true))
    #expect(mock.deleteDomainCallCount == 0)
  }

  @Test("v6 duplicate with a disabled entry reports an existing disabled entry")
  func v6DuplicateDisabled() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(.alreadyPresent)
    mock.getDomainStub = .success(DomainEntry(id: 9, domain: "x.com", type: 0, comment: "user", enabled: false))
    let decorator = makeDecorator(service: mock)
    let outcome = try await decorator.unblockDomain(
      "x.com", duration: 300, ownershipID: Self.t1)
    #expect(outcome == .alreadyPresent(enabled: false))
    #expect(mock.deleteDomainCallCount == 0)
  }

  @Test("v6 duplicate carrying our token records the orphan and reports added")
  func v6OrphanToken() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(.alreadyPresent)
    mock.getDomainStub = .success(
      DomainEntry(
        id: 9, domain: "x.com", type: 0, comment: "via holeberryapp.com / \(Self.t1.uuidString)", enabled: true))
    let suite = TestDefaults.makeSuite()
    let decorator = makeParkingDecorator(service: mock, suite: suite)
    let outcome = try await decorator.unblockDomain(
      "x.com", duration: 300, ownershipID: Self.t1)
    #expect(outcome == .added)
    #expect(Defaults[.tempUnblocks(for: mock.id, suite: suite)].count == 1)
  }

  @Test("v6 re-unblock of our own record renews the timer")
  func v6Renew() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(.added)
    let suite = TestDefaults.makeSuite()
    let decorator = makeParkingDecorator(service: mock, suite: suite)
    _ = try await decorator.unblockDomain(
      "x.com", duration: 300, ownershipID: Self.t1)
    #expect(Defaults[.tempUnblocks(for: mock.id, suite: suite)].count == 1)

    mock.addDomainStub = .success(.alreadyPresent)
    mock.getDomainStub = .success(
      DomainEntry(
        id: 9, domain: "x.com", type: 0, comment: "via holeberryapp.com / \(Self.t1.uuidString)", enabled: true))
    let outcome = try await decorator.unblockDomain(
      "x.com", duration: 300, ownershipID: Self.t2)
    #expect(outcome == .renewed)
    let records = Defaults[.tempUnblocks(for: mock.id, suite: suite)]
    #expect(records.count == 1)
    #expect(records.first?.uuid == "via holeberryapp.com / \(Self.t1.uuidString)")
  }

  @Test("v6 indefinite on our own record promotes it")
  func v6Promote() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(.added)
    let suite = TestDefaults.makeSuite()
    let decorator = makeParkingDecorator(service: mock, suite: suite)
    _ = try await decorator.unblockDomain(
      "x.com", duration: 300, ownershipID: Self.t1)

    mock.addDomainStub = .success(.alreadyPresent)
    mock.getDomainStub = .success(
      DomainEntry(
        id: 9, domain: "x.com", type: 0, comment: "via holeberryapp.com / \(Self.t1.uuidString)", enabled: true))
    let outcome = try await decorator.unblockDomain(
      "x.com", duration: nil, ownershipID: Self.t2)
    #expect(outcome == .promoted)
    #expect(Defaults[.tempUnblocks(for: mock.id, suite: suite)].isEmpty)
  }

  @Test("v6 400 triggers exactly one read-back and classifies")
  func v6FallbackReadBack() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .failure(PiholeError.server(400, #"{"error":{"key":"database_error"}}"#))
    mock.getDomainStub = .success(DomainEntry(id: 3, domain: "x.com", type: 0, comment: "user", enabled: true))
    let decorator = makeDecorator(service: mock)
    #expect(
      try await decorator.unblockDomain("x.com", duration: 60, ownershipID: Self.t1)
        == .alreadyPresent(enabled: true))
    #expect(mock.getDomainCallCount == 1)
  }

  @Test("v6 400 with an empty read-back rethrows the original error")
  func v6FallbackRethrows() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .failure(PiholeError.server(400, "database_error"))
    mock.getDomainStub = .success(nil)
    let decorator = makeDecorator(service: mock)
    await #expect(throws: PiholeError.server(400, "database_error")) {
      _ = try await decorator.unblockDomain("x.com", duration: 60, ownershipID: Self.t1)
    }
  }

  @Test("expiry: a foreign comment skips the delete and sends no notification")
  func expiryForeignCommentSkipsDelete() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(.added)
    mock.getDomainStub = .success(DomainEntry(id: 9, domain: "x.com", type: 0, comment: "user", enabled: true))

    let suite = TestDefaults.makeSuite()
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
      defaultsSuite: suite,
      notificationCenter: center
    ) { _ in }
    _ = try await decorator.unblockDomain(
      "x.com", duration: 0.5, ownershipID: Self.t1)

    #expect(
      await eventually { Defaults[.tempUnblocks(for: mock.id, suite: suite)].isEmpty },
      "Record should be dropped after a not-ours expiry")
    #expect(mock.deleteDomainCallCount == 0, "A foreign entry must never be deleted")
    #expect(posted.domains.isEmpty, "A foreign entry must not claim 'blocked again'")
  }

  @Test("expiry: our comment deletes and notifies")
  func expiryOurCommentDeletes() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(.added)
    mock.getDomainStub = .success(
      DomainEntry(
        id: 42, domain: "x.com", type: 0, comment: "via holeberryapp.com / \(Self.t1.uuidString)", enabled: true))
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
    _ = try await decorator.unblockDomain(
      "x.com", duration: 0.5, ownershipID: Self.t1)

    #expect(await eventually { mock.deleteDomainCallCount == 1 }, "Our own entry must be deleted")
    #expect(await eventually { posted.domains.contains("x.com") }, "The user is told the unblock ended")
  }

  @Test("expiry: entry already absent finalizes without delete")
  func expiryAbsentFinalizes() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(.added)
    mock.getDomainStub = .success(nil)

    let suite = TestDefaults.makeSuite()
    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: mock,
      defaultsSuite: suite
    ) { _ in }
    _ = try await decorator.unblockDomain(
      "x.com", duration: 0.5, ownershipID: Self.t1)

    #expect(await eventually { Defaults[.tempUnblocks(for: mock.id, suite: suite)].isEmpty })
    #expect(mock.deleteDomainCallCount == 0)
  }

  @Test("expiry: delete 404 finalizes")
  func expiry404Finalizes() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(.added)
    mock.getDomainStub = .success(
      DomainEntry(
        id: 42, domain: "x.com", type: 0, comment: "via holeberryapp.com / \(Self.t1.uuidString)", enabled: true))
    mock.deleteDomainStub = .failure(PiholeError.server(404, ""))

    let suite = TestDefaults.makeSuite()
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
      defaultsSuite: suite,
      notificationCenter: center
    ) { _ in }
    _ = try await decorator.unblockDomain(
      "x.com", duration: 0.5, ownershipID: Self.t1)

    #expect(
      await eventually { Defaults[.tempUnblocks(for: mock.id, suite: suite)].isEmpty },
      "A 404 means the entry is already gone — finalize, do not retry")
    #expect(await eventually { posted.domains.contains("x.com") })
  }

  @Test("expiry: v5 ignores ownership")
  func expiryV5DeletesWithoutComment() async throws {
    let mock = MockPiholeService(version: .v5)
    mock.getDomainsStub = .success([DomainEntry(id: 1, domain: "x.com", type: 0, comment: nil)])
    mock.getDomainStub = .success(DomainEntry(id: 1, domain: "x.com", type: 0, comment: nil, enabled: true))
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
      "v5 has no ownership marker — the allow entry is deleted as today, but typed")
  }

}
