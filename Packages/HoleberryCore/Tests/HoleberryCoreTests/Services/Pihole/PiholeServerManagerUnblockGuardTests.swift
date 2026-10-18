import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("PiholeServerManager in-progress unblocks")
struct PiholeServerManagerUnblockGuardTests {
  private func makeManager(services: [MockPiholeService]) -> PiholeServerManager {
    let suite = TestDefaults.makeSuite()
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
      if service.unblockDomainOwnershipIDs.count == 1 {
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
    #expect(service.unblockDomainOwnershipIDs.count == 1, "Duplicates must not reach Pi-hole")
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
      if busy.unblockDomainOwnershipIDs.count == 1 {
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
    #expect(busy.unblockDomainOwnershipIDs.count == 1)
    #expect(available.unblockDomainOwnershipIDs.count == 1)
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

  @Test("The in-progress guard stays active through retry backoff")
  func guardDuringRetry() async throws {
    let service = MockPiholeService()
    let manager = makeManager(services: [service])
    service.addDomainStubQueue = [.failure(PiholeError.network("response lost")), .success(.added)]
    let first = Task { try await manager.unblock(domain: "example.com", duration: 60) }
    await waitUntil { service.addDomainCallCount == 1 }

    let duplicate = try await manager.unblock(domain: "example.com", duration: 60)
    #expect(service.addDomainCallCount == 1, "A duplicate must not insert during retry backoff")
    #expect(duplicate[service.id] == .inProgress)
    #expect(try await first.value[service.id] == .added)
    #expect(service.addDomainCallCount == 2)
    #expect(Set(service.unblockDomainOwnershipIDs).count == 1)
  }
}
