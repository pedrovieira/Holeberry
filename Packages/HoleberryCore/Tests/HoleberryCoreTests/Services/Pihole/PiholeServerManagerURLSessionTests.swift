import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("PiholeServerManager URL sessions")
struct PiholeServerManagerURLSessionTests {
  private let storage = MockAppStorage()
  private let serviceFactory = MockPiholeServiceFactory()
  private let versionDetector = MockPiholeVersionDetector()

  @Test("loadServers trusts every configured host")
  func loadServersTrustsEveryConfiguredHost() {
    let first = ServerConfig(label: "A", url: "https://a.local", version: .v6)
    let second = ServerConfig(label: "B", url: "https://b.local", version: .v6)
    storage.servers = [first, second]
    let factory = MockURLSessionFactory()

    _ = PiholeServerManager(
      storage: storage,
      serviceFactory: serviceFactory,
      versionDetector: versionDetector,
      urlSessionFactory: factory
    )

    #expect(factory.makeSessionCallCount == 2)
    #expect(
      factory.trustedHostsHistory == [
        ["a.local", "b.local"],
        ["a.local", "b.local"]
      ])
  }

  @Test("addServer invalidates the detection session and keeps the service session")
  func addServerInvalidatesDetectionSession() async throws {
    let factory = MockURLSessionFactory()
    var sessions: [MockURLSession] = []
    factory.makeSessionHandler = {
      let session = MockURLSession()
      sessions.append(session)
      return session
    }
    let manager = PiholeServerManager(
      storage: storage,
      serviceFactory: serviceFactory,
      versionDetector: versionDetector,
      urlSessionFactory: factory
    )

    try await manager.addServer(label: "Test", url: "https://test.local", credential: "secret")

    #expect(factory.makeSessionCallCount == 2, "one detection session and one service session")
    #expect(factory.trustedHostsHistory == [["test.local"], ["test.local"]])
    #expect(sessions.count == 2)
    #expect(sessions[0].invalidateAndCancelCallCount == 1)
    #expect(sessions[1].invalidateAndCancelCallCount == 0)
  }
}
