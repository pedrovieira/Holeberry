import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("Browser unblock with managed timers")
struct BrowserDomainUnblockIntegrationTests {
  struct ServerQueryScenario: Sendable {
    let first: DomainQueryHandling?
    let second: DomainQueryHandling?
    let skipsCreation: Bool
  }

  @Test(
    "ALLOW or BLOCK from either or both servers",
    arguments: [
      ServerQueryScenario(first: .permitted, second: nil, skipsCreation: true),
      ServerQueryScenario(first: nil, second: .permitted, skipsCreation: true),
      ServerQueryScenario(first: .permitted, second: .permitted, skipsCreation: true),
      ServerQueryScenario(first: .ruleBlocked, second: nil, skipsCreation: false),
      ServerQueryScenario(first: nil, second: .ruleBlocked, skipsCreation: false),
      ServerQueryScenario(first: .ruleBlocked, second: .ruleBlocked, skipsCreation: false),
      ServerQueryScenario(first: .permitted, second: .ruleBlocked, skipsCreation: false),
      ServerQueryScenario(first: .ruleBlocked, second: .permitted, skipsCreation: false),
      ServerQueryScenario(first: .permitted, second: .upstreamBlocked, skipsCreation: false),
      ServerQueryScenario(first: .upstreamBlocked, second: .permitted, skipsCreation: false),
      ServerQueryScenario(first: nil, second: nil, skipsCreation: false)
    ]
  )
  func queryStatusOnEitherOrBothServers(scenario: ServerQueryScenario) async throws {
    let suite = TestDefaults.makeSuite()
    let rawServices = [MockPiholeAPI(version: .v6), MockPiholeAPI(version: .v5)]
    let services = rawServices.map { raw in
      TemporaryUnblockPiholeServiceDecorator(
        service: raw, defaultsSuite: suite, retrySleep: { _ in },
        sleep: { _ in try await Task.sleep(for: .seconds(60)) })
    }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    for (raw, handling) in zip(rawServices, [scenario.first, scenario.second]) {
      raw.getDomainQueryHistoryHandler = { domain, _, _ in
        let entries =
          handling.map { handling in
            [
              DomainQueryEntry(
                domain: domain, timestamp: now.addingTimeInterval(-10), queryType: "A",
                clientIP: "192.168.1.50", handling: handling,
                status: handling == .permitted ? "ALLOW" : "BLOCK", reply: "IP")
            ]
          } ?? []
        return DomainQueryHistory(entries: entries, isComplete: true)
      }
    }
    let manager = makeManager(service: services[0], suite: suite, otherService: services[1])
    let resolver = MockLocalIPAddressResolver()
    resolver.stubbedIP = "192.168.1.50"
    let workflow = LiveBrowserDomainUnblocker(manager: manager, networkInterface: resolver, now: { now })

    let result = await workflow.unblock(domain: "example.com", duration: 300)

    #expect(result.outcome == (scenario.skipsCreation ? .notBlocked : .processed))
    #expect(result.allowedDomains == (scenario.skipsCreation ? ["example.com", "www.example.com"] : []))
    for raw in rawServices {
      let records = Defaults[.tempUnblocks(for: raw.id, suite: suite)]
      #expect(raw.addDomainCallCount == (scenario.skipsCreation ? 0 : 2))
      #expect(Set(records.map(\.domain)) == (scenario.skipsCreation ? [] : ["example.com", "www.example.com"]))
      #expect(records.allSatisfy { $0.durationSeconds == 300 })
    }
    if !scenario.skipsCreation {
      for service in services {
        try await service.deleteDomain("example.com", from: .allow)
        try await service.deleteDomain("www.example.com", from: .allow)
      }
    }
  }

  @Test(arguments: [false, true])
  func allowedHistoryLeavesExistingTimersUnchanged(permanent: Bool) async throws {
    let raw = MockPiholeAPI()
    let suite = TestDefaults.makeSuite()
    let service = TemporaryUnblockPiholeServiceDecorator(
      service: raw, defaultsSuite: suite, retrySleep: { _ in },
      sleep: { _ in try await Task.sleep(for: .seconds(60)) })
    let otherService = MockPiholeService()
    let manager = makeManager(service: service, suite: suite, otherService: otherService)
    // Both exact hostnames have an owned temporary entry before their queries become allowed.
    _ = try await service.unblockDomain("example.com", duration: 300)
    _ = try await service.unblockDomain("www.example.com", duration: 300)
    let initial = Defaults[.tempUnblocks(for: raw.id, suite: suite)]
    raw.getDomainHandler = { domain in
      guard let record = initial.first(where: { $0.domain == domain }) else { return nil }
      return DomainEntry(id: 1, domain: domain, type: 0, comment: record.uuid, enabled: true)
    }
    raw.getDomainQueryHistoryHandler = { domain, client, interval in
      DomainQueryHistory(
        entries: [
          DomainQueryEntry(
            domain: domain, timestamp: interval.end.addingTimeInterval(-1), queryType: "A",
            clientIP: client, handling: .permitted, status: "CACHE", reply: "IP")
        ], isComplete: true)
    }
    let resolver = MockLocalIPAddressResolver()
    resolver.stubbedIP = "192.168.1.50"
    let workflow = LiveBrowserDomainUnblocker(manager: manager, networkInterface: resolver)

    let result = await workflow.unblock(domain: "example.com", duration: permanent ? nil : 1800)

    #expect(result.outcome == .notBlocked)
    #expect(result.allowedDomains == ["example.com", "www.example.com"])
    #expect(raw.addDomainCallCount == 2, "ALLOW must not create additional entries")
    #expect(otherService.unblockDomainCallCount == 0, "The other server needs no matching history")
    let records = Defaults[.tempUnblocks(for: raw.id, suite: suite)]
    #expect(records == initial)
    #expect(result.mutations.isEmpty)
    try await service.deleteDomain("example.com", from: .allow)
    try await service.deleteDomain("www.example.com", from: .allow)
  }

  @Test(arguments: [false, true])
  func absentEvidenceStillCreatesManagedAllowances(missingIP: Bool) async throws {
    let raw = MockPiholeAPI()
    let suite = TestDefaults.makeSuite()
    let service = TemporaryUnblockPiholeServiceDecorator(
      service: raw, defaultsSuite: suite, retrySleep: { _ in },
      sleep: { _ in try await Task.sleep(for: .seconds(60)) })
    let manager = makeManager(service: service, suite: suite)
    let resolver = MockLocalIPAddressResolver()
    resolver.stubbedIP = missingIP ? nil : "192.168.1.50"
    let workflow = LiveBrowserDomainUnblocker(manager: manager, networkInterface: resolver)

    let result = await workflow.unblock(domain: "example.com", duration: 300)

    #expect(result.outcome == .processed)
    #expect(result.allowedDomains.isEmpty)
    let records = Defaults[.tempUnblocks(for: raw.id, suite: suite)]
    #expect(Set(records.map(\.domain)) == ["example.com", "www.example.com"])
    #expect(records.allSatisfy { $0.durationSeconds == 300 })
    #expect(raw.addDomainCallCount == 2)
    try await service.deleteDomain("example.com", from: .allow)
    try await service.deleteDomain("www.example.com", from: .allow)
  }

  private func makeManager(
    service: any PiholeServiceProviding, suite: UserDefaults, otherService: (any PiholeServiceProviding)? = nil
  ) -> PiholeServerManager {
    let services = [service] + (otherService.map { [$0] } ?? [])
    Defaults[.servers(suite: suite)] = services.map {
      ServerConfig(id: $0.id, url: $0.url, version: $0.version)
    }
    let factory = MockPiholeServiceFactory()
    factory.buildServiceHandler = { config in services.first { $0.id == config.id }! }
    return PiholeServerManager(
      keychain: MockKeychainManager(), serviceFactory: factory,
      versionDetector: MockPiholeVersionDetector(), suite: suite)
  }
}
