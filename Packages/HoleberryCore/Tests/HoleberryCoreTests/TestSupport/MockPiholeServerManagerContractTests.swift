import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("MockPiholeServerManager contracts")
struct MockPiholeServerManagerContractTests {
  @Test(
    "Missing or blank labels fall back to the hostname",
    arguments: [nil, "", " \t\n"] as [String?]
  )
  func blankDisplayLabel(label: String?) {
    let manager = MockPiholeServerManager()
    let config = ServerConfig(label: label, url: "http://home.local:8080/admin", version: .v6)
    manager.servers = [config]
    #expect(manager.displayLabel(for: config.id) == "home.local")
  }

  @Test func historyAndMutationArgumentsArePreserved() async throws {
    let manager = MockPiholeServerManager()
    let config = ServerConfig(label: "Home", url: "http://home.local", version: .v6)
    manager.servers = [config]
    let interval = DateInterval(start: Date(timeIntervalSince1970: 1000), duration: 900)
    let history = DomainQueryHistory(entries: [], isComplete: false)
    manager.getDomainQueryHistoryStub = ["example.com": [config.id: .success(history)]]
    let result = await manager.getDomainQueryHistory(
      domains: ["example.com"], forClientIP: "192.168.1.50", interval: interval)
    #expect(try result["example.com"]?[config.id]?.get() == history)
    #expect(manager.getDomainQueryHistoryCallCount == 1)
    #expect(manager.getDomainQueryHistoryLastDomains == ["example.com"])
    #expect(manager.getDomainQueryHistoryLastClientIP == "192.168.1.50")
    #expect(manager.getDomainQueryHistoryLastInterval == interval)
    #expect(manager.getDomainQueryHistoryLastServerIDs == [config.id])
    #expect(manager.displayLabel(for: config.id) == "Home")
    let added = ServerConfig(url: "http://new.local", version: .v6)
    manager.servers.append(added)
    manager.applyDomainUnblockHandler = { domain, duration, ids, mode in
      #expect(domain == "example.com")
      #expect(duration == nil)
      #expect(ids == [config.id, added.id])
      #expect(mode == .existingOnly)
      return [config.id: .success(.promoted)]
    }
    let mutation = await manager.applyDomainUnblock(
      domain: "example.com", duration: nil, mode: .existingOnly)
    #expect(try mutation[config.id]?.get() == .promoted)
    #expect(manager.applyDomainUnblockCallCount == 1)
    #expect(manager.applyDomainUnblockArgs.first?.mode == .existingOnly)
  }
}
