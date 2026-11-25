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
    // Require the count before indexing, so a missing session reports instead of trapping.
    try #require(sessions.count == 2, "one detection session and one service session")
    #expect(sessions[0].invalidateAndCancelCallCount == 1)
    #expect(sessions[1].invalidateAndCancelCallCount == 0)
    // The service must own the second session, not some other transport.
    let serviceSession = try #require(serviceFactory.buildServiceLastSession)
    #expect(serviceSession as AnyObject === sessions[1])
  }

  @Test("addServer discards the service session when construction fails")
  func addServerInvalidatesServiceSessionWhenBuildFails() async throws {
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
    serviceFactory.buildServiceError = URLSessionFactoryTestError.buildFailed

    await #expect(throws: URLSessionFactoryTestError.self) {
      try await manager.addServer(label: "Test", url: "https://test.local", credential: "secret")
    }

    try #require(sessions.count == 2, "one detection session and one service session")
    #expect(sessions[0].invalidateAndCancelCallCount == 1)
    #expect(sessions[1].invalidateAndCancelCallCount == 1, "the orphaned service session must be cancelled")
    #expect(manager.servers.isEmpty)
  }

  @Test("addServer logs the service out when login fails")
  func addServerLogsOutWhenLoginFails() async throws {
    let service = MockPiholeService()
    service.loginStub = .failure(URLSessionFactoryTestError.loginFailed)
    serviceFactory.buildServiceStub = service
    let manager = PiholeServerManager(
      storage: storage,
      serviceFactory: serviceFactory,
      versionDetector: versionDetector,
      urlSessionFactory: MockURLSessionFactory()
    )

    await #expect(throws: URLSessionFactoryTestError.self) {
      try await manager.addServer(label: "Test", url: "https://test.local", credential: "secret")
    }

    #expect(service.logoutCallCount == 1, "logout is what tears down the service's session")
    #expect(manager.servers.isEmpty)
  }

  @Test("addServer logs the service out when credential persistence fails")
  func addServerLogsOutWhenCredentialSaveFails() async throws {
    let service = MockPiholeService()
    serviceFactory.buildServiceStub = service
    // Login succeeds, so a v6 session may already exist server-side when the save fails.
    storage.saveCredentialStub = .failure(URLSessionFactoryTestError.saveFailed)
    let manager = PiholeServerManager(
      storage: storage,
      serviceFactory: serviceFactory,
      versionDetector: versionDetector,
      urlSessionFactory: MockURLSessionFactory()
    )

    await #expect(throws: URLSessionFactoryTestError.self) {
      try await manager.addServer(label: "Test", url: "https://test.local", credential: "secret")
    }

    #expect(service.loginCallCount == 1)
    #expect(service.logoutCallCount == 1, "a half-added server must not keep a server-side session")
    #expect(manager.servers.isEmpty)
  }

  @Test("verifyCredential discards the probe session when construction fails")
  func verifyCredentialInvalidatesSessionWhenBuildFails() async throws {
    storage.servers = [ServerConfig(label: "A", url: "https://a.local", version: .v6)]
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
    let sessionsAfterLoad = sessions.count
    let id = try #require(manager.servers.first?.id)
    serviceFactory.buildServiceError = URLSessionFactoryTestError.buildFailed

    await #expect(throws: URLSessionFactoryTestError.self) {
      _ = try await manager.verifyCredential(id: id, credential: "secret")
    }

    try #require(sessions.count == sessionsAfterLoad + 1)
    #expect(sessions[sessionsAfterLoad].invalidateAndCancelCallCount == 1)
  }
}

private enum URLSessionFactoryTestError: Error {
  case buildFailed
  case loginFailed
  case saveFailed
}
