import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("Managed unblock mutation retries")
struct TempUnblockMutationRetryTests {
  @MainActor
  private final class Backoff {
    var durations: [Duration] = []
    var continuation: CheckedContinuation<Void, any Error>?

    func record(_ duration: Duration) {
      durations.append(duration)
    }

    func sleepIgnoringCancellation(_ duration: Duration) async throws {
      durations.append(duration)
      try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func sleep(_ duration: Duration) async throws {
      durations.append(duration)
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation = $0 }
      } onCancel: {
        Task { @MainActor in self.release(error: CancellationError()) }
      }
    }

    func release(error: (any Error)? = nil) {
      let pending = continuation
      continuation = nil
      if let error {
        pending?.resume(throwing: error)
      } else {
        pending?.resume()
      }
    }
  }

  @Test("One direct call exhausts three attempts and propagates the mutation error")
  func exhaustion() async throws {
    let raw = MockPiholeService()
    let failure = PiholeError.network("mutation response lost")
    raw.addDomainStub = .failure(failure)
    raw.getDomainStub = .failure(PiholeError.network("recovery read failed"))
    let suite = TestDefaults.makeSuite()
    let backoff = Backoff()
    let service = TemporaryUnblockPiholeServiceDecorator(
      service: raw, defaultsSuite: suite,
      retrySleep: { duration in await backoff.record(duration) },
      sleep: { _ in Issue.record("Failed mutations must not schedule expiry") })

    await #expect(throws: failure) { try await service.unblockDomain("Example.COM", duration: 300) }

    #expect(raw.addDomainCallCount == 3)
    #expect(raw.getDomainCallCount == 3)
    #expect(raw.addDomainLastDomain == "example.com")
    #expect(backoff.durations == [.seconds(1), .seconds(2)])
    let token = try #require(raw.addDomainComments.first ?? nil)
    #expect(token.hasPrefix("via holeberryapp.com / "))
    #expect(UUID(uuidString: String(token.dropFirst("via holeberryapp.com / ".count))) != nil)
    #expect(raw.addDomainComments == [token, token, token])
    #expect(Defaults[.tempUnblocks(for: raw.id, suite: suite)].isEmpty)
  }

  @Test("A later attempt recovers a committed insert using the original request token")
  func committedInsertRecovery() async throws {
    let raw = MockPiholeService()
    let suite = TestDefaults.makeSuite()
    var committed: DomainEntry?
    raw.addDomainHandler = { domain, _, comment in
      if committed != nil { return .alreadyPresent }
      committed = DomainEntry(id: 1, domain: domain, type: 0, comment: comment, enabled: true)
      throw PiholeError.network("insert committed but response lost")
    }
    raw.getDomainHandler = { _ in
      if raw.getDomainCallCount == 1 { throw PiholeError.network("first recovery read failed") }
      return committed
    }
    let service = TemporaryUnblockPiholeServiceDecorator(
      service: raw, defaultsSuite: suite, retrySleep: { _ in }, sleep: { _ in throw CancellationError() })

    #expect(try await service.unblockDomain("Example.COM", duration: 300) == .added)
    let records = Defaults[.tempUnblocks(for: raw.id, suite: suite)]
    let record = try #require(records.first)
    #expect(records.count == 1)
    #expect(raw.addDomainCallCount == 2)
    #expect(raw.getDomainCallCount == 2)
    #expect(raw.addDomainComments == [record.uuid, record.uuid])
    #expect(record.domain == "example.com")
    #expect(record.uuid == committed?.comment)

    #expect(try await service.unblockDomain("example.com", duration: 600) == .renewed)
    #expect(raw.addDomainComments.last != raw.addDomainComments.first)
    let renewed = Defaults[.tempUnblocks(for: raw.id, suite: suite)]
    #expect(renewed.count == 1)
    #expect(renewed.first?.uuid == record.uuid)
    #expect(renewed.first?.durationSeconds == 600)
    try await service.deleteDomain("example.com", from: .allow)
    #expect(Defaults[.tempUnblocks(for: raw.id, suite: suite)].isEmpty)
  }

  @Test("Nonretryable mutation errors propagate after one attempt")
  func nonretryable() async throws {
    let raw = MockPiholeService()
    let failure = PiholeError.server(403, "forbidden")
    raw.addDomainStub = .failure(failure)
    let suite = TestDefaults.makeSuite()
    let service = TemporaryUnblockPiholeServiceDecorator(
      service: raw, defaultsSuite: suite,
      retrySleep: { _ in Issue.record("Nonretryable errors must not back off") },
      sleep: { _ in Issue.record("Failed mutations must not schedule expiry") })

    await #expect(throws: failure) { try await service.unblockDomain("example.com", duration: 300) }
    #expect(raw.addDomainCallCount == 1)
    #expect(raw.getDomainCallCount == 1)
    #expect(Defaults[.tempUnblocks(for: raw.id, suite: suite)].isEmpty)
  }

  @Test("Cancellation during mutation backoff prevents any later attempt")
  func cancellationInBackoff() async throws {
    let raw = MockPiholeService()
    raw.addDomainStub = .failure(PiholeError.network("offline"))
    let suite = TestDefaults.makeSuite()
    let backoff = Backoff()
    let service = TemporaryUnblockPiholeServiceDecorator(
      service: raw, defaultsSuite: suite, retrySleep: { try await backoff.sleep($0) },
      sleep: { _ in Issue.record("Failed mutations must not schedule expiry") })
    let unblock = Task { try await service.unblockDomain("example.com", duration: 300) }
    await waitUntil { backoff.continuation != nil }
    unblock.cancel()

    await #expect(throws: CancellationError.self) { try await unblock.value }
    #expect(raw.addDomainCallCount == 1)
    #expect(raw.getDomainCallCount == 1)
    #expect(backoff.durations == [.seconds(1)])
    #expect(Defaults[.tempUnblocks(for: raw.id, suite: suite)].isEmpty)
    raw.addDomainStub = .success(.added)
    #expect(try await service.unblockDomain("example.com", duration: nil) == .added)
    #expect(raw.addDomainCallCount == 2)
  }

  @Test("A cancelled call cannot mutate even if its backoff ignores cancellation")
  func cancellationBeforeNextAttempt() async throws {
    let raw = MockPiholeService()
    raw.addDomainStub = .failure(PiholeError.network("offline"))
    let backoff = Backoff()
    let service = TemporaryUnblockPiholeServiceDecorator(
      service: raw, defaultsSuite: TestDefaults.makeSuite(),
      retrySleep: { try await backoff.sleepIgnoringCancellation($0) })
    let unblock = Task { try await service.unblockDomain("example.com", duration: nil) }
    await waitUntil { backoff.continuation != nil }
    unblock.cancel()
    backoff.release()

    await #expect(throws: CancellationError.self) { try await unblock.value }
    #expect(raw.addDomainCallCount == 1)
  }

  @Test("The decorator releases its domain gate during mutation backoff")
  func releasesGateBetweenAttempts() async throws {
    let raw = MockPiholeService()
    raw.addDomainStubQueue = [.failure(PiholeError.network("offline")), .success(.added)]
    let backoff = Backoff()
    let service = TemporaryUnblockPiholeServiceDecorator(
      service: raw, defaultsSuite: TestDefaults.makeSuite(), retrySleep: { try await backoff.sleep($0) })
    let unblock = Task { try await service.unblockDomain("example.com", duration: nil) }
    await waitUntil { backoff.continuation != nil }
    var deleted = false
    let deletion = Task {
      try await service.deleteDomain("example.com", from: .allow)
      deleted = true
    }
    await waitUntil { deleted }
    #expect(raw.deleteDomainCallCount == 1)
    #expect(raw.addDomainCallCount == 1)
    backoff.release()

    try await deletion.value
    #expect(try await unblock.value == .added)
    #expect(raw.addDomainCallCount == 2)
  }

  @Test("General add remains outside managed retry policy")
  func generalAddDoesNotRetry() async throws {
    let raw = MockPiholeService()
    let failure = PiholeError.network("offline")
    raw.addDomainStub = .failure(failure)
    let service = TemporaryUnblockPiholeServiceDecorator(
      service: raw, defaultsSuite: TestDefaults.makeSuite(),
      retrySleep: { _ in Issue.record("General adds must not use managed retries") })

    await #expect(throws: failure) { try await service.addDomain("example.com", to: .allow, comment: "manual") }
    #expect(raw.addDomainCallCount == 1)
    #expect(raw.addDomainLastComment == "manual")
    #expect(raw.getDomainCallCount == 0)
  }
}
