import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("DomainHistoryFanout")
struct PiholeDomainHistoryFanoutTests {
  private func manager(_ services: [MockPiholeService]) -> PiholeServerManager {
    let suite = TestDefaults.makeSuite()
    Defaults[.servers(suite: suite)] = services.map { ServerConfig(id: $0.id, url: $0.url, version: $0.version) }
    let factory = MockPiholeServiceFactory()
    factory.buildServiceHandler = { config in services.first { $0.id == config.id }! }
    return PiholeServerManager(
      keychain: MockKeychainManager(), serviceFactory: factory,
      versionDetector: MockPiholeVersionDetector(), suite: suite)
  }

  @Test func mixedReadsKeepEveryCandidateAndServer() async throws {
    let good = MockPiholeService()
    let bad = MockPiholeService()
    let manager = manager([good, bad])
    let interval = DateInterval(start: Date(timeIntervalSince1970: 1000), duration: 900)
    bad.getDomainQueryHistoryStub = .failure(PiholeError.unauthorized)
    good.getDomainQueryHistoryHandler = { domain, client, requestedInterval in
      #expect(client == "192.168.1.50")
      #expect(requestedInterval == interval)
      return DomainQueryHistory(
        entries: [
          DomainQueryEntry(
            domain: domain, timestamp: interval.start, queryType: "A",
            clientIP: client, handling: .ruleBlocked, status: "GRAVITY", reply: nil)
        ], isComplete: true)
    }
    let result = await manager.getDomainQueryHistory(
      domains: ["example.com", "www.example.com"], forClientIP: "192.168.1.50", interval: interval)
    #expect(result.count == 2)
    for domain in ["example.com", "www.example.com"] {
      #expect(try result[domain]?[good.id]?.get().entries.first?.domain == domain)
      #expect(result[domain]?[bad.id] == .failure(.unauthorized))
    }
  }

  @Test func eachCallUsesCurrentlyConfiguredServers() async throws {
    let retained = MockPiholeService()
    let removed = MockPiholeService()
    let manager = manager([retained, removed])
    let interval = DateInterval(start: Date(), duration: 900)
    let firstRead = await manager.getDomainQueryHistory(
      domains: ["example.com"], forClientIP: "192.168.1.50", interval: interval)
    #expect(firstRead["example.com"]?.count == 2)
    #expect(firstRead["example.com"]?[retained.id] != nil)
    #expect(firstRead["example.com"]?[removed.id] != nil)

    manager.deleteServer(id: removed.id)
    let newConfig = ServerConfig(url: "http://new.local", version: .v6)
    manager.servers.append(newConfig)
    let nextRead = await manager.getDomainQueryHistory(
      domains: ["example.com"], forClientIP: "192.168.1.50", interval: interval)
    #expect(nextRead["example.com"]?.count == 2)
    #expect(nextRead["example.com"]?[removed.id] == nil)
    #expect(nextRead["example.com"]?[newConfig.id] == .failure(.unknown("Server not found")))
    #expect(removed.getDomainQueryHistoryCallCount == 1)

    let writes = await manager.applyDomainUnblock(
      domain: "www.example.com", duration: 60, mode: .allowCreation)
    #expect(try writes[retained.id]?.get() == .added)
    #expect(writes[removed.id] == nil)
    #expect(writes[newConfig.id] == .failure(.unknown("Server not found")))
    #expect(retained.unblockDomainLastDomain == "www.example.com")
    #expect(removed.unblockDomainCallCount == 0)
  }

  @Test func mutationModesAndPartialErrorsRemainDistinct() async throws {
    let good = MockPiholeService()
    let bad = MockPiholeService()
    let manager = manager([good, bad])
    bad.unblockExistingDomainStub = .failure(PiholeError.network("offline"))
    let result = await manager.applyDomainUnblock(
      domain: "WWW.EXAMPLE.COM", duration: nil, mode: .existingOnly)
    #expect(try result[good.id]?.get() == nil)
    #expect(result[bad.id] == .failure(.network("offline")))
    #expect(good.unblockDomainCallCount == 0)
    #expect(good.unblockExistingDomainLastDomain == "www.example.com")
    #expect(good.unblockExistingDomainLastDuration == nil)
  }
}
