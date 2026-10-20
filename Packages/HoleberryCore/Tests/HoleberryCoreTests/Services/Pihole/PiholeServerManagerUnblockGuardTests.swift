import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("PiholeServerManager in-progress unblocks")
struct PiholeServerManagerUnblockGuardTests {
  private func makeManager(
    services: [any PiholeServiceProviding], suite: UserDefaults = TestDefaults.makeSuite()
  ) -> PiholeServerManager {
    Defaults[.servers(suite: suite)] = services.map {
      ServerConfig(id: $0.id, url: $0.url, version: $0.version)
    }
    let factory = MockPiholeServiceFactory()
    factory.buildServiceHandler = { config in
      services.first { $0.id == config.id }!
    }
    return PiholeServerManager(
      keychain: MockKeychainManager(),
      serviceFactory: factory,
      versionDetector: MockPiholeVersionDetector(),
      suite: suite
    )
  }

  @Test("Overlapping temporary and permanent requests skip a normalized domain", arguments: [ServerVersion.v5, .v6])
  func overlappingRequests(version: ServerVersion) async throws {
    let service = MockPiholeService(version: version)
    let manager = makeManager(services: [service])
    var pending: CheckedContinuation<Void, Never>?
    service.unblockDomainHandler = { _, _ in
      if service.unblockDomainCallCount == 1 {
        await withCheckedContinuation { pending = $0 }
        return .added
      }
      return .alreadyPresent(enabled: true)
    }
    let first = Task { try await manager.unblock(domain: "www.example.com", duration: 60) }
    await waitUntil { pending != nil }
    defer { pending?.resume() }

    let duplicate = try await manager.unblock(domain: "EXAMPLE.COM", duration: 300)
    let permanent = await manager.addToAllowlist(domain: "WWW.EXAMPLE.COM")
    #expect(service.unblockDomainCallCount == 1, "Duplicates must not reach Pi-hole")
    #expect(duplicate[service.id] == .inProgress, "A duplicate must not trigger a no-op notification")
    #expect(permanent[service.id] == .inProgress)

    pending?.resume()
    pending = nil
    #expect(try await first.value[service.id] == .added)
    service.unblockDomainHandler = nil
    #expect(try await manager.unblock(domain: "example.com", duration: 300)[service.id] == .added)
  }

  @Test("A different domain can unblock while one is running")
  func independentDomains() async throws {
    let service = MockPiholeService()
    let manager = makeManager(services: [service])
    var pending: CheckedContinuation<Void, Never>?
    service.unblockDomainHandler = { domain, _ in
      if domain == "example.com" {
        await withCheckedContinuation { pending = $0 }
      }
      return .added
    }
    let first = Task { try await manager.unblock(domain: "example.com", duration: 60) }
    await waitUntil { pending != nil }
    defer { pending?.resume() }

    #expect(try await manager.unblock(domain: "other.com", duration: 60)[service.id] == .added)
    pending?.resume()
    pending = nil
    _ = try await first.value
  }

  @Test("A busy server does not suppress an unblock on another server")
  func independentServers() async throws {
    let busy = MockPiholeService()
    let available = MockPiholeService()
    let manager = makeManager(services: [busy, available])
    let configs = manager.servers
    manager.servers = configs.filter { $0.id == busy.id }
    var pending: CheckedContinuation<Void, Never>?
    busy.unblockDomainHandler = { _, _ in
      if busy.unblockDomainCallCount == 1 {
        await withCheckedContinuation { pending = $0 }
      }
      return .added
    }
    let first = Task { try await manager.unblock(domain: "example.com", duration: 60) }
    await waitUntil { pending != nil }
    defer { pending?.resume() }

    manager.servers = configs
    let duplicate = try await manager.unblock(domain: "example.com", duration: 60)
    #expect(duplicate[busy.id] == .inProgress)
    #expect(duplicate[available.id] == .added)
    #expect(busy.unblockDomainCallCount == 1)
    #expect(available.unblockDomainCallCount == 1)
    pending?.resume()
    pending = nil
    _ = try await first.value
  }

  @Test("Failed and cancelled operations allow a subsequent unblock", arguments: [false, true])
  func releaseAfterFailure(cancel: Bool) async throws {
    let service = MockPiholeService()
    let manager = makeManager(services: [service])
    var pending: CheckedContinuation<Void, Never>?
    service.unblockDomainHandler = { _, _ in
      await withCheckedContinuation { pending = $0 }
      try Task.checkCancellation()
      throw PiholeError.invalidCredentials
    }
    let first = Task { try await manager.unblock(domain: "example.com", duration: 60) }
    await waitUntil { pending != nil }
    if cancel { first.cancel() }
    pending?.resume()
    pending = nil
    await #expect(throws: (any Error).self) { try await first.value }

    service.unblockDomainHandler = nil
    #expect(try await manager.unblock(domain: "example.com", duration: 60)[service.id] == .added)
  }

  /// Separate instances control mutation backoff, expiry, and completion independently.
  @MainActor
  private final class Gate {
    private var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var waitingCount: Int { waiting.count }

    func wait() async throws {
      let id = UUID()
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { waiting[id] = $0 }
      } onCancel: {
        Task { @MainActor in
          self.waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
      }
    }

    func release() {
      let continuations = Array(waiting.values)
      waiting.removeAll()
      for continuation in continuations { continuation.resume() }
    }

    func cancel() {
      let continuations = Array(waiting.values)
      waiting.removeAll()
      for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
  }

  enum Completion: CaseIterable {
    case success
    case failure
    case cancellation
  }

  @Test("The manager guard spans managed retry and persistence, then releases", arguments: Completion.allCases)
  func guardDuringManagedRetry(completion: Completion) async throws {
    let suite = TestDefaults.makeSuite()
    let raw = MockPiholeAPI()
    let backoff = Gate()
    let expiry = Gate()
    let persisted = Gate()
    defer {
      backoff.cancel()
      expiry.cancel()
      persisted.cancel()
    }
    raw.addDomainStub = .failure(PiholeError.network("response lost"))
    if completion == .success {
      raw.addDomainStubQueue = [.failure(PiholeError.network("response lost")), .success(.added)]
    }
    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: raw, defaultsSuite: suite,
      retrySleep: { _ in try await backoff.wait() },
      sleep: { _ in try await expiry.wait() })
    let managed = MockPiholeService(id: raw.id)
    managed.unblockDomainHandler = { domain, duration in
      let outcome = try await decorator.unblockDomain(domain, duration: duration)
      if managed.unblockDomainCallCount == 1 {
        #expect(Defaults[.tempUnblocks(for: raw.id, suite: suite)].count == 1)
        try await persisted.wait()
      }
      return outcome
    }
    let manager = makeManager(services: [managed], suite: suite)
    let first = Task { try await manager.unblock(domain: "example.com", duration: 60) }
    await waitUntil { backoff.waitingCount == 1 }

    #expect(try await manager.unblock(domain: "www.example.com", duration: 300)[raw.id] == .inProgress)
    #expect(await manager.addToAllowlist(domain: "EXAMPLE.COM")[raw.id] == .inProgress)
    #expect(managed.unblockDomainCallCount == 1)
    #expect(raw.addDomainCallCount == 1)

    switch completion {
    case .success:
      backoff.release()
      await waitUntil { persisted.waitingCount == 1 }
      #expect(raw.addDomainCallCount == 2)
      #expect(Defaults[.tempUnblocks(for: raw.id, suite: suite)].count == 1)
      #expect(try await manager.unblock(domain: "example.com", duration: 60)[raw.id] == .inProgress)
      #expect(managed.unblockDomainCallCount == 1)
      persisted.release()
      #expect(try await first.value[raw.id] == .added)
    case .failure:
      backoff.release()
      await waitUntil { raw.addDomainCallCount == 2 && backoff.waitingCount == 1 }
      backoff.release()
      await #expect(throws: PiholeError.network("response lost")) { try await first.value }
      #expect(raw.addDomainCallCount == 3)
    case .cancellation:
      first.cancel()
      await #expect(throws: CancellationError.self) { try await first.value }
      #expect(raw.addDomainCallCount == 1, "Cancellation during mutation backoff must prevent another insert")
    }

    raw.addDomainStub = .success(.added)
    #expect(try await manager.unblock(domain: "example.com", duration: 300)[raw.id] == .added)
    #expect(managed.unblockDomainCallCount == 2, "The completed call must release the manager guard")
    #expect(Defaults[.tempUnblocks(for: raw.id, suite: suite)].count == 1)
    try await decorator.deleteDomain("example.com", from: .allow)
  }

  @Test("Managed unblocks on two servers generate independent ownership tokens")
  func independentServerTokens() async throws {
    let suite = TestDefaults.makeSuite()
    let rawServices = [MockPiholeAPI(), MockPiholeAPI()]
    let expiry = Gate()
    defer { expiry.cancel() }
    let decorators = rawServices.map { raw in
      TemporaryUnblockPiholeServiceDecorator(
        service: raw, defaultsSuite: suite, retrySleep: { _ in }, sleep: { _ in try await expiry.wait() })
    }
    let managed = zip(rawServices, decorators).map { raw, decorator in
      let service = MockPiholeService(id: raw.id)
      service.unblockDomainHandler = { domain, duration in
        try await decorator.unblockDomain(domain, duration: duration)
      }
      return service
    }
    let manager = makeManager(services: managed, suite: suite)
    let outcomes = try await manager.unblock(domain: "example.com", duration: 60)
    #expect(outcomes.count == 2)
    #expect(outcomes.values.allSatisfy { $0 == .added })
    let firstToken = try #require(rawServices[0].addDomainLastComment)
    let secondToken = try #require(rawServices[1].addDomainLastComment)
    #expect(firstToken != secondToken)
    for index in rawServices.indices {
      let raw = rawServices[index]
      #expect(managed[index].unblockDomainCallCount == 1)
      #expect(Defaults[.tempUnblocks(for: raw.id, suite: suite)].first?.uuid == raw.addDomainLastComment)
      try await decorators[index].deleteDomain("example.com", from: .allow)
    }
  }
}
