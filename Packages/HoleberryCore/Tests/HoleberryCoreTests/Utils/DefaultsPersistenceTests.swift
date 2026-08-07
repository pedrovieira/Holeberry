import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@Suite("Defaults Persistence")
@MainActor
struct DefaultsPersistenceTests {
  @Test func serversEmptyByDefault() {
    let suite = TestDefaults.makeSuite()
    #expect(Defaults[.servers(suite: suite)].isEmpty)
  }

  @Test func notifyWhenUnblockEndsDefaultsToTrue() {
    let suite = TestDefaults.makeSuite()
    #expect(Defaults[.notifyWhenUnblockEnds(suite: suite)] == true)

    Defaults[.notifyWhenUnblockEnds(suite: suite)] = false
    #expect(Defaults[.notifyWhenUnblockEnds(suite: suite)] == false)
  }

  @Test func notifyWhenDomainUnblockEndsDefaultsToTrue() {
    let suite = TestDefaults.makeSuite()
    #expect(Defaults[.notifyWhenDomainUnblockEnds(suite: suite)] == true)

    Defaults[.notifyWhenDomainUnblockEnds(suite: suite)] = false
    #expect(Defaults[.notifyWhenDomainUnblockEnds(suite: suite)] == false)
  }

  @Test func serversSaveAndLoad() {
    let suite = TestDefaults.makeSuite()
    let server = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    let loaded = Defaults[.servers(suite: suite)]
    #expect(loaded.count == 1)
    #expect(loaded[0].id == server.id)
    #expect(loaded[0].url == "http://test.com")
  }

  @Test func serversOverwrite() {
    let suite = TestDefaults.makeSuite()
    let server1 = ServerConfig(label: "A", url: "http://a.com", version: .v6)
    let server2 = ServerConfig(label: "B", url: "http://b.com", version: .v6)
    Defaults[.servers(suite: suite)] = [server1]
    Defaults[.servers(suite: suite)] = [server2]
    let loaded = Defaults[.servers(suite: suite)]
    #expect(loaded.count == 1)
    #expect(loaded[0].id == server2.id)
  }

  @Test func serversMultiple() {
    let suite = TestDefaults.makeSuite()
    let server1 = ServerConfig(label: "A", url: "http://a.com", version: .v6)
    let server2 = ServerConfig(label: "B", url: "http://b.com", version: .v6)
    Defaults[.servers(suite: suite)] = [server1, server2]
    let loaded = Defaults[.servers(suite: suite)]
    #expect(loaded.count == 2)
  }

  @Test func serversCorruptedData() {
    let suite = TestDefaults.makeSuite()
    // Can't write corrupted data through Defaults (it encodes properly),
    // so inject bad JSON directly via UserDefaults to test the error path.
    suite.set("<bad json>", forKey: "servers")
    let mockFactory = ConcretePiholeServiceFactory(
      authSessionFactory: MockAuthSessionFactory(),
      htmlParser: PiholeV5HTMLParser()
    )
    let manager = PiholeServerManager(
      keychain: MockKeychainManager(),
      serviceFactory: mockFactory,
      versionDetector: PiholeVersionDetector(),
      suite: suite
    )
    #expect(manager.servers.isEmpty)
  }
}
