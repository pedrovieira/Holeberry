import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("Temporary unblock concurrency")
struct TempUnblockConcurrencyTests {
  enum CleanupPhase: CaseIterable {
    case lookup
    case delete
  }

  /// Intentionally ignores cancellation until released, like work already in flight.
  @MainActor
  private final class Sleeps {
    var waiting: [CheckedContinuation<Void, any Error>] = []

    func sleep(_ duration: TimeInterval) async throws {
      try await withCheckedThrowingContinuation { waiting.append($0) }
    }

    func releaseFirst() {
      waiting.removeFirst().resume()
    }

    func cancelAll() {
      let pending = waiting
      waiting.removeAll()
      for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }
  }

  @MainActor
  private final class Server {
    var entries: [String: DomainEntry] = [:]

    func configure(_ mock: MockPiholeAPI) {
      mock.addDomainHandler = { domain, _, comment in
        guard self.entries[domain] == nil else { return .alreadyPresent }
        self.entries[domain] = DomainEntry(id: 1, domain: domain, type: 0, comment: comment, enabled: true)
        return .added
      }
      mock.getDomainHandler = { domain in self.entries[domain] }
      mock.deleteDomainHandler = { domain, _ in self.entries[domain] = nil }
    }
  }

  @Test(
    "An in-flight cleanup finishes before a fresh temporary or permanent unblock",
    arguments: CleanupPhase.allCases, [TimeInterval?.none, .some(3600)])
  func cleanupBeforeUnblock(phase: CleanupPhase, duration: TimeInterval?) async throws {
    let mock = MockPiholeAPI()
    let server = Server()
    server.configure(mock)
    let suite = TestDefaults.makeSuite()
    let sleeps = Sleeps()
    defer { sleeps.cancelAll() }
    var network: CheckedContinuation<Void, Never>?
    mock.getDomainHandler = { domain in
      if phase == .lookup, mock.getDomainCallCount == 1 {
        await withCheckedContinuation { network = $0 }
      }
      return server.entries[domain]
    }
    mock.deleteDomainHandler = { domain, _ in
      if phase == .delete {
        await withCheckedContinuation { network = $0 }
      }
      server.entries[domain] = nil
    }
    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: mock, defaultsSuite: suite, sleep: sleeps.sleep)
    _ = try await decorator.unblockDomain("x.com", duration: 300)
    await waitUntil { sleeps.waiting.count == 1 }
    sleeps.releaseFirst()
    await waitUntil { network != nil }

    var started = false
    var finished = false
    let unblock = Task {
      started = true
      defer { finished = true }
      return try await decorator.unblockDomain("X.COM", duration: duration)
    }
    await waitUntil { started }
    await settle()
    #expect(!finished, "The new unblock must wait for the old network operation")
    // A different domain can still proceed while this cleanup is suspended.
    #expect(try await decorator.unblockDomain("other.com", duration: nil) == .added)
    network?.resume()

    #expect(try await unblock.value == .added)
    await settle()
    #expect(server.entries["x.com"] != nil)
    let records = Defaults[.tempUnblocks(for: mock.id, suite: suite)]
    if duration != nil {
      let record = try #require(records.first)
      #expect(record.durationSeconds == 3600)
      #expect(!record.pendingRemoval)
      #expect(record.uuid == server.entries["x.com"]?.comment)
      #expect(record.uuid == mock.addDomainLastComment)
    } else {
      #expect(records.isEmpty)
    }
  }

  @Test("A failed expiry or retry cannot mark a renewed record for deletion", arguments: [false, true])
  func failedCleanupBeforeRenewal(isRetry: Bool) async throws {
    let mock = MockPiholeAPI()
    let server = Server()
    server.configure(mock)
    let suite = TestDefaults.makeSuite()
    let sleeps = Sleeps()
    defer { sleeps.cancelAll() }
    var network: CheckedContinuation<Void, any Error>?
    var pauseLookup = !isRetry
    mock.getDomainHandler = { domain in
      if pauseLookup {
        pauseLookup = false
        try await withCheckedThrowingContinuation { network = $0 }
      }
      return server.entries[domain]
    }
    mock.deleteDomainHandler = { _, _ in throw PiholeError.server(500, "Offline") }
    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: mock, defaultsSuite: suite, sleep: sleeps.sleep)
    _ = try await decorator.unblockDomain("x.com", duration: 300)
    await waitUntil { sleeps.waiting.count == 1 }
    sleeps.releaseFirst()
    if isRetry {
      await waitUntil { sleeps.waiting.count == 1 }
      pauseLookup = true
      sleeps.releaseFirst()
    }
    await waitUntil { network != nil }
    var started = false
    let unblock = Task {
      started = true
      return try await decorator.unblockDomain("x.com", duration: 3600)
    }
    await waitUntil { started }
    await settle()
    pauseLookup = false
    network?.resume(throwing: CancellationError())
    #expect(try await unblock.value == .renewed)
    await settle()

    let renewed = try #require(Defaults[.tempUnblocks(for: mock.id, suite: suite)].first)
    #expect(renewed.durationSeconds == 3600)
    #expect(!renewed.pendingRemoval)
    #expect(renewed.retryCount == 0)
    #expect(server.entries["x.com"] != nil)
  }

  @Test(
    "Late expiry and retry wakeups cannot delete renewed or promoted entries",
    arguments: [false, true], [false, true])
  func staleWakeup(isRetry: Bool, permanent: Bool) async throws {
    let mock = MockPiholeAPI()
    let server = Server()
    server.configure(mock)
    let suite = TestDefaults.makeSuite()
    let sleeps = Sleeps()
    defer { sleeps.cancelAll() }
    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: mock, defaultsSuite: suite, sleep: sleeps.sleep)
    _ = try await decorator.unblockDomain("x.com", duration: 300)
    await waitUntil { sleeps.waiting.count == 1 }
    if isRetry {
      mock.deleteDomainHandler = { _, _ in throw PiholeError.server(500, "Offline") }
      sleeps.releaseFirst()
      await waitUntil { sleeps.waiting.count == 1 }
      mock.deleteDomainHandler = { domain, _ in server.entries[domain] = nil }
    }
    let outcome = try await decorator.unblockDomain(
      "x.com", duration: permanent ? nil : 3600)
    #expect(outcome == (permanent ? .promoted : .renewed))
    let reads = mock.getDomainCallCount
    sleeps.releaseFirst()
    await settle()

    #expect(mock.getDomainCallCount == reads, "Stale cleanup must exit before contacting Pi-hole")
    #expect(server.entries["x.com"] != nil)
    let records = Defaults[.tempUnblocks(for: mock.id, suite: suite)]
    #expect(records.count == (permanent ? 0 : 1))
    #expect(records.first?.pendingRemoval != true)
  }

  @Test("Explicit allow deletion waits for an in-flight unblock to finish")
  func deleteDuringUnblock() async throws {
    let mock = MockPiholeAPI()
    let suite = TestDefaults.makeSuite()
    let sleeps = Sleeps()
    defer { sleeps.cancelAll() }
    var network: CheckedContinuation<Void, Never>?
    var entry: DomainEntry?
    mock.addDomainHandler = { domain, _, comment in
      await withCheckedContinuation { network = $0 }
      entry = DomainEntry(id: 1, domain: domain, type: 0, comment: comment)
      return .added
    }
    mock.deleteDomainHandler = { _, _ in entry = nil }
    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: mock, defaultsSuite: suite, sleep: sleeps.sleep)
    let unblock = Task { try await decorator.unblockDomain("x.com", duration: 300) }
    await waitUntil { network != nil }
    var started = false
    let deletion = Task {
      started = true
      try await decorator.deleteDomain("X.COM", from: .allow)
    }
    await waitUntil { started }
    await settle()
    network?.resume()
    _ = try await unblock.value
    try await deletion.value

    #expect(entry == nil)
    #expect(Defaults[.tempUnblocks(for: mock.id, suite: suite)].isEmpty)
  }

  @Test("A cancelled queued unblock does not mutate the entry or strand the next request")
  func cancelledWaiter() async throws {
    let mock = MockPiholeAPI()
    let server = Server()
    server.configure(mock)
    let sleeps = Sleeps()
    defer { sleeps.cancelAll() }
    var network: CheckedContinuation<Void, Never>?
    mock.addDomainHandler = { domain, _, comment in
      if mock.addDomainCallCount == 1 {
        await withCheckedContinuation { network = $0 }
        server.entries[domain] = DomainEntry(id: 1, domain: domain, type: 0, comment: comment)
        return .added
      }
      return .alreadyPresent
    }
    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: mock, defaultsSuite: TestDefaults.makeSuite(), sleep: sleeps.sleep)
    let first = Task { try await decorator.unblockDomain("x.com", duration: 300) }
    await waitUntil { network != nil }
    var started = false
    let cancelled = Task {
      started = true
      return try await decorator.unblockDomain("x.com", duration: 3600)
    }
    await waitUntil { started }
    await settle()
    cancelled.cancel()
    let next = Task { try await decorator.unblockDomain("x.com", duration: nil) }
    await settle()
    network?.resume()
    _ = try await first.value

    await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    #expect(try await next.value == .promoted)
    #expect(mock.addDomainCallCount == 2, "The cancelled request must never reach Pi-hole")
  }

  @Test(
    "Delayed startup reconciliation cannot overwrite a renewal or promotion",
    arguments: [false, true], [false, true])
  func staleReconciliation(fails: Bool, permanent: Bool) async throws {
    let mock = MockPiholeAPI()
    let server = Server()
    server.configure(mock)
    let suite = TestDefaults.makeSuite()
    let sleeps = Sleeps()
    defer { sleeps.cancelAll() }
    let token = "via holeberryapp.com / \(UUID().uuidString)"
    server.entries["x.com"] = DomainEntry(id: 1, domain: "x.com", type: 0, comment: token)
    Defaults[.tempUnblocks(for: mock.id, suite: suite)] = [
      TempUnblockRecord(
        domain: "x.com", uuid: token, startDateUTC: Date(), durationSeconds: 300,
        pendingRemoval: true, retryCount: 2)
    ]
    var network: CheckedContinuation<[DomainEntry], any Error>?
    mock.getDomainsHandler = { _ in
      try await withCheckedThrowingContinuation { network = $0 }
    }
    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: mock, defaultsSuite: suite, sleep: sleeps.sleep)
    await waitUntil { network != nil }
    let outcome = try await decorator.unblockDomain(
      "x.com", duration: permanent ? nil : 3600)
    #expect(outcome == (permanent ? .promoted : .renewed))
    if fails {
      network?.resume(throwing: URLError(.timedOut))
    } else {
      // The list response predates the unblock, so its missing row is stale.
      network?.resume(returning: [])
    }
    await settle()

    let records = Defaults[.tempUnblocks(for: mock.id, suite: suite)]
    #expect(records.count == (permanent ? 0 : 1))
    #expect(records.first?.pendingRemoval != true)
    #expect(sleeps.waiting.count == (permanent ? 0 : 1), "Only the current timer should be scheduled")
    #expect(server.entries["x.com"] != nil)
  }

  @Test("A busy restored domain does not delay restoring other domains' timers")
  func independentReconciliation() async throws {
    let mock = MockPiholeAPI()
    let server = Server()
    server.configure(mock)
    let suite = TestDefaults.makeSuite()
    let sleeps = Sleeps()
    defer { sleeps.cancelAll() }
    let records = ["x.com", "y.com"].map {
      TempUnblockRecord(domain: $0, uuid: UUID().uuidString, startDateUTC: Date(), durationSeconds: 300)
    }
    Defaults[.tempUnblocks(for: mock.id, suite: suite)] = records
    for record in records {
      server.entries[record.domain] = DomainEntry(id: 1, domain: record.domain, type: 0, comment: record.uuid)
    }
    var listing: CheckedContinuation<[DomainEntry], Never>?
    var addition: CheckedContinuation<Void, Never>?
    mock.getDomainsHandler = { _ in await withCheckedContinuation { listing = $0 } }
    mock.addDomainHandler = { _, _, _ in
      await withCheckedContinuation { addition = $0 }
      return .alreadyPresent
    }
    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: mock, defaultsSuite: suite, sleep: sleeps.sleep)
    await waitUntil { listing != nil }
    let renewal = Task { try await decorator.unblockDomain("x.com", duration: 3600) }
    await waitUntil { addition != nil }
    listing?.resume(returning: Array(server.entries.values))
    await settle()

    #expect(sleeps.waiting.count == 1, "y.com's timer must start while x.com's request is still waiting")
    addition?.resume()
    #expect(try await renewal.value == .renewed)
    await settle()
    #expect(sleeps.waiting.count == 2)
  }
}
