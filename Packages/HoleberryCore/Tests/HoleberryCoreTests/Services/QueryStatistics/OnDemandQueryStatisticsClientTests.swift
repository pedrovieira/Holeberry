import Defaults
import Foundation
import Testing

@testable import HoleberryCore

private struct StatisticsReadFailure: Error {}


/// A v6 transport that holds the summary request until the test cancels it and
/// records whether the session DELETE ran inside a cancelled task.
private final class CancellationAwareV6Transport: HTTPRequestable, @unchecked Sendable {
  private let lock = NSLock()
  private var log: [String] = []
  private var deleteCancelled: Bool?
  private var invalidations = 0
  @MainActor private var heldSummary: CheckedContinuation<(Data, URLResponse), any Error>?

  @MainActor var events: [String] {
    lock.lock()
    defer { lock.unlock() }
    return log
  }

  @MainActor var deleteWasCancelled: Bool? {
    lock.lock()
    defer { lock.unlock() }
    return deleteCancelled
  }

  @MainActor var invalidationCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return invalidations
  }

  private func record(_ event: String) {
    lock.lock()
    log.append(event)
    lock.unlock()
  }

  private func recordDelete(cancelled: Bool) {
    lock.lock()
    deleteCancelled = cancelled
    log.append(cancelled ? "delete-cancelled" : "delete")
    lock.unlock()
  }

  @MainActor
  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let method = request.httpMethod ?? "GET"
    let path = request.url?.path ?? ""
    if method == "POST" && path == "/api/auth" {
      record("auth")
      let body = #"{"session":{"valid":true,"sid":"test-sid","csrf":"test-csrf","validity":300,"totp":false}}"#
      return (Data(body.utf8), response(for: request, status: 200))
    }
    if method == "GET" && path == "/api/stats/summary" {
      record("summary")
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          if Task.isCancelled {
            continuation.resume(throwing: URLError(.cancelled))
          } else {
            self.heldSummary = continuation
          }
        }
      } onCancel: {
        Task { @MainActor in
          self.heldSummary?.resume(throwing: URLError(.cancelled))
          self.heldSummary = nil
        }
      }
    }
    if method == "DELETE" && path == "/api/auth" {
      let cancelled = Task.isCancelled
      recordDelete(cancelled: cancelled)
      // Mimics URLSession refusing work from a cancelled task.
      if cancelled { throw URLError(.cancelled) }
      return (Data(), response(for: request, status: 204))
    }
    throw URLError(.unsupportedURL)
  }

  func invalidateAndCancel() {
    lock.lock()
    invalidations += 1
    log.append("invalidate")
    lock.unlock()
  }

  private func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
  }
}

@MainActor
@Suite("OnDemandQueryStatisticsClient")
struct OnDemandQueryStatisticsClientTests {
  /// Read-only wrapper that fails one server's credential read without adding
  /// any write capability.
  private struct FailingCredentialReader: ConnectionReading {
    let base: any ConnectionReading
    let failingServerID: UUID
    var error: any Error = StatisticsReadFailure()

    func loadServers() -> [ServerConfig] { base.loadServers() }

    func readCredential(for serverID: UUID) throws -> String? {
      if serverID == failingServerID { throw error }
      return try base.readCredential(for: serverID)
    }
  }

  /// A published App Group copy, a real read-only reader, and mock seams.
  @MainActor
  private final class Harness {
    let suite: UserDefaults
    let suiteName: String
    let keychain = MockKeychainManager()
    let sharedStorage: StubSharedStorage
    let reader: ConcreteSharedStorageReader
    let sessionProvider = MockOnDemandSessionProvider()
    let factory = MockPiholeServiceFactory()

    init() {
      let named = TestDefaults.makeNamedSuite()
      suite = named.suite
      suiteName = named.name
      sharedStorage = StubSharedStorage(
        location: SharedStorageLocation(suite: named.suite, suiteName: named.name),
        keychain: keychain
      )
      reader = ConcreteSharedStorageReader(sharedStorage: sharedStorage)
    }

    func publish(_ servers: [ServerConfig], credentials: [UUID: String] = [:]) {
      Defaults[.servers(suite: suite)] = servers
      Defaults[.sharedStorageMigrationVersion(suite: suite)] = SharedStorageValidation.currentVersion
      for (id, credential) in credentials {
        keychain.storedCredentials[id.uuidString] = credential
      }
    }

    /// The real read-only connection reader, not a writable store.
    func openConnections() throws -> any ConnectionReading {
      try reader.openConnectionReader()
    }

    func makeClient(connections: any ConnectionReading) -> OnDemandQueryStatisticsClient {
      OnDemandQueryStatisticsClient(
        connections: connections,
        serviceFactory: factory,
        sessionProvider: sessionProvider
      )
    }

    /// Serves one mock service per configured identifier.
    func serve(_ services: [UUID: MockPiholeService]) {
      factory.buildServiceHandler = { config in
        services[config.id] ?? MockPiholeService(id: config.id, url: config.url, version: config.version)
      }
    }

    /// A v6 transport that authenticates and answers a summary for the healthy server.
    ///
    /// Each handler declines other paths, so it stays queued for the next request.
    static func makeV6Session() -> MockURLSession {
      let session = MockURLSession()
      session.handlers = [
        { request in
          guard request.url?.path == "/api/auth" else { throw MockURLSession.Mismatch.declined }
          let body = #"{"session":{"valid":true,"sid":"test-sid","csrf":"test-csrf","validity":300,"totp":false}}"#
          return (
            Data(body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
          )
        },
        { request in
          guard request.url?.path == "/api/stats/summary" else { throw MockURLSession.Mismatch.declined }
          return (
            Data(#"{"queries":{"total":12,"blocked":3}}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
          )
        }
      ]
      return session
    }

    func makeServer(_ label: String, version: ServerVersion = .v6) -> ServerConfig {
      ServerConfig(label: label, url: "http://\(label.lowercased()).local", version: version)
    }
  }

  @Test func realFactoryReportsABrokenSavedAddressAsAPerServerFailure() async throws {
    let harness = Harness()
    let broken = ServerConfig(id: UUID(), label: "Broken", url: "http://[broken", version: .v6)
    let healthy = harness.makeServer("Healthy")
    harness.publish([broken, healthy], credentials: [broken.id: "a", healthy.id: "b"])
    harness.sessionProvider.sessionFactory = { Harness.makeV6Session() }
    // The real production factory, not the mock, must not trap on an unparsable URL.
    let factory = ConcretePiholeServiceFactory(onDemand: ConcreteAuthSessionFactory())
    let client = OnDemandQueryStatisticsClient(
      connections: try harness.openConnections(),
      serviceFactory: factory,
      sessionProvider: harness.sessionProvider
    )

    let batch = await client.fetchStatistics(scope: .all)

    #expect(batch.servers.map(\.id) == [broken.id, healthy.id])
    #expect(
      batch.results[broken.id] == .failure(.unknown("Saved server address is invalid")),
      "the failure must not include the saved address or a secret")
    #expect(batch.results[healthy.id] == .success(QuerySummary(totalQueries: 12, totalBlocked: 3)))
    // The broken server's transport was created before its build failed, so the
    // client releases it at once; the healthy one is released by logout.
    #expect(harness.sessionProvider.createdMockSessions.map(\.invalidateAndCancelCallCount) == [1, 0])

    await client.logout()

    // The broken server's session has no owner, so the client releases it once.
    // The healthy v6 service invalidates its own session during logout, and the
    // client may release its owned reference again; a repeated
    // `invalidateAndCancel` is a no-op on a real URLSession.
    let sessions = harness.sessionProvider.createdMockSessions
    #expect(sessions.count == 2)
    #expect(sessions[0].invalidateAndCancelCallCount == 1, "a failed build releases its transport exactly once")
    #expect(sessions[1].invalidateAndCancelCallCount >= 1)
  }

  // MARK: - Scoping and building

  @Test func buildsOnlyTheSelectedServer() async throws {
    let harness = Harness()
    let first = harness.makeServer("First")
    let second = harness.makeServer("Second", version: .v5)
    harness.publish([first, second], credentials: [first.id: "first-secret", second.id: "second-secret"])
    let firstService = MockPiholeService(id: first.id, url: first.url, version: first.version)
    let secondService = MockPiholeService(id: second.id, url: second.url, version: second.version)
    firstService.getQuerySummaryStub = .success(QuerySummary(totalQueries: 12, totalBlocked: 3))
    harness.serve([first.id: firstService, second.id: secondService])
    let client = harness.makeClient(connections: try harness.openConnections())

    let batch = await client.fetchStatistics(scope: .server(first.id))
    await client.logout()

    #expect(batch.servers.map(\.id) == [first.id])
    #expect(Set(batch.results.keys) == [first.id])
    #expect(batch.results[first.id] == .success(QuerySummary(totalQueries: 12, totalBlocked: 3)))
    #expect(firstService.getQuerySummaryCallCount == 1)
    #expect(secondService.getQuerySummaryCallCount == 0)
    #expect(harness.factory.buildServiceCallCount == 1)
    #expect(harness.sessionProvider.makeSessionCallCount == 1)
    #expect(harness.sessionProvider.createdMockSessions.map(\.invalidateAndCancelCallCount) == [1])
  }

  @Test func allScopeBuildsEverySavedServer() async throws {
    let harness = Harness()
    let first = harness.makeServer("First")
    let second = harness.makeServer("Second")
    harness.publish([first, second], credentials: [first.id: "a", second.id: "b"])
    let firstService = MockPiholeService(id: first.id, url: first.url, version: first.version)
    let secondService = MockPiholeService(id: second.id, url: second.url, version: second.version)
    harness.serve([first.id: firstService, second.id: secondService])
    let client = harness.makeClient(connections: try harness.openConnections())

    let batch = await client.fetchStatistics(scope: .all)
    await client.logout()

    #expect(batch.servers.map(\.id) == [first.id, second.id])
    #expect(Set(batch.results.keys) == [first.id, second.id])
    #expect(firstService.getQuerySummaryCallCount == 1)
    #expect(secondService.getQuerySummaryCallCount == 1)
    #expect(harness.factory.buildServiceCallCount == 2)
    #expect(harness.sessionProvider.createdMockSessions.map(\.invalidateAndCancelCallCount) == [1, 1])
  }

  @Test func missingSelectedServerFetchesNothing() async throws {
    let harness = Harness()
    let saved = harness.makeServer("Saved")
    harness.publish([saved], credentials: [saved.id: "secret"])
    let client = harness.makeClient(connections: try harness.openConnections())

    let batch = await client.fetchStatistics(scope: .server(UUID()))
    await client.logout()

    #expect(batch.servers.isEmpty)
    #expect(batch.results.isEmpty)
    #expect(harness.factory.buildServiceCallCount == 0)
    #expect(harness.sessionProvider.makeSessionCallCount == 0)
    #expect(harness.sessionProvider.createdSessions.isEmpty)
    #expect(harness.keychain.readCredentialCallCount == 0)
  }

  // MARK: - Request behavior

  @Test func neverWarmsUpAuthentication() async throws {
    let harness = Harness()
    let server = harness.makeServer("Home")
    harness.publish([server], credentials: [server.id: "secret"])
    let service = MockPiholeService(id: server.id, url: server.url, version: server.version)
    harness.serve([server.id: service])
    let client = harness.makeClient(connections: try harness.openConnections())

    _ = await client.fetchStatistics(scope: .all)
    await client.logout()

    #expect(service.loginCallCount == 0)
    #expect(service.getQuerySummaryCallCount == 1)
    #expect(harness.sessionProvider.createdMockSessions.map(\.invalidateAndCancelCallCount) == [1])
  }

  @Test func sessionsTrustEveryConfiguredHost() async throws {
    let harness = Harness()
    let first = harness.makeServer("First")
    let second = harness.makeServer("Second")
    harness.publish([first, second], credentials: [first.id: "a", second.id: "b"])
    harness.serve([:])
    let client = harness.makeClient(connections: try harness.openConnections())

    _ = await client.fetchStatistics(scope: .server(first.id))
    await client.logout()

    #expect(harness.sessionProvider.makeSessionCallCount == 1)
    #expect(harness.sessionProvider.makeSessionLastTrustedHosts == ["first.local", "second.local"])
    #expect(harness.sessionProvider.createdMockSessions.map(\.invalidateAndCancelCallCount) == [1])
  }

  @Test func failedFetchKeepsPerServerResultsWithoutClientLevelRetries() async throws {
    let harness = Harness()
    let failing = harness.makeServer("Failing")
    let healthy = harness.makeServer("Healthy")
    harness.publish([failing, healthy], credentials: [failing.id: "a", healthy.id: "b"])
    let failingService = MockPiholeService(id: failing.id, url: failing.url, version: failing.version)
    let healthyService = MockPiholeService(id: healthy.id, url: healthy.url, version: healthy.version)
    failingService.getQuerySummaryStub = .failure(PiholeError.server(500, nil))
    healthyService.getQuerySummaryStub = .success(QuerySummary(totalQueries: 5, totalBlocked: 1))
    harness.serve([failing.id: failingService, healthy.id: healthyService])
    let client = harness.makeClient(connections: try harness.openConnections())

    let batch = await client.fetchStatistics(scope: .all)
    await client.logout()

    #expect(batch.results[failing.id] == .failure(.server(500, nil)))
    #expect(batch.results[healthy.id] == .success(QuerySummary(totalQueries: 5, totalBlocked: 1)))
    #expect(
      failingService.getQuerySummaryCallCount == 1,
      "the client adds no retries beyond the service's own semantics")
    #expect(harness.sessionProvider.createdMockSessions.map(\.invalidateAndCancelCallCount) == [1, 1])
  }

  // MARK: - Credentials

  @Test func missingCredentialUsesThePasswordlessPath() async throws {
    let harness = Harness()
    let server = harness.makeServer("Passwordless")
    harness.publish([server])
    let service = MockPiholeService(id: server.id, url: server.url, version: server.version)
    harness.serve([server.id: service])
    let client = harness.makeClient(connections: try harness.openConnections())

    let batch = await client.fetchStatistics(scope: .all)
    await client.logout()

    #expect(harness.factory.buildServiceLastCredential == "")
    #expect(batch.results[server.id] == .success(QuerySummary(totalQueries: 0, totalBlocked: 0)))
  }

  @Test func failedCredentialReadIsAFailureNotAbsence() async throws {
    let harness = Harness()
    let unreadable = harness.makeServer("Unreadable")
    let healthy = harness.makeServer("Healthy")
    harness.publish([unreadable, healthy], credentials: [unreadable.id: "a", healthy.id: "b"])
    let healthyService = MockPiholeService(id: healthy.id, url: healthy.url, version: healthy.version)
    harness.serve([healthy.id: healthyService])
    let connections = try harness.openConnections()
    let client = harness.makeClient(
      connections: FailingCredentialReader(base: connections, failingServerID: unreadable.id)
    )

    let batch = await client.fetchStatistics(scope: .all)
    await client.logout()

    guard case .failure(.unknown)? = batch.results[unreadable.id] else {
      Issue.record("A generic read failure must stay a typed unknown failure, not absence")
      return
    }
    #expect(batch.results[healthy.id] == .success(QuerySummary(totalQueries: 0, totalBlocked: 0)))
    #expect(harness.factory.buildServiceCallCount == 1)
    #expect(harness.factory.buildServiceLastConfig?.id == healthy.id)
  }

  @Test func typedCredentialReadFailureIsPreserved() async throws {
    let harness = Harness()
    let unreadable = harness.makeServer("Unreadable")
    harness.publish([unreadable], credentials: [unreadable.id: "a"])
    let connections = try harness.openConnections()
    let client = harness.makeClient(
      connections: FailingCredentialReader(
        base: connections, failingServerID: unreadable.id, error: PiholeError.invalidCredentials)
    )

    let batch = await client.fetchStatistics(scope: .all)
    await client.logout()

    #expect(batch.results[unreadable.id] == .failure(.invalidCredentials))
    #expect(harness.factory.buildServiceCallCount == 0)
  }

  @Test func failedServiceBuildKeepsThatServersFailure() async throws {
    let harness = Harness()
    let unbuildable = harness.makeServer("Unbuildable")
    let healthy = harness.makeServer("Healthy")
    harness.publish([unbuildable, healthy], credentials: [unbuildable.id: "a", healthy.id: "b"])
    let healthyService = MockPiholeService(id: healthy.id, url: healthy.url, version: healthy.version)
    harness.serve([healthy.id: healthyService])
    harness.factory.buildServiceErrorsByConfig[unbuildable.id] = PiholeError.unknown("bad configuration")
    let client = harness.makeClient(connections: try harness.openConnections())

    let batch = await client.fetchStatistics(scope: .all)

    // The session created for the failed build has no service owner, so the
    // client releases it immediately; the healthy one lives until logout.
    #expect(harness.sessionProvider.createdMockSessions.map(\.invalidateAndCancelCallCount) == [1, 0])
    #expect(batch.results[unbuildable.id] == .failure(.unknown("bad configuration")))
    #expect(batch.results[healthy.id] == .success(QuerySummary(totalQueries: 0, totalBlocked: 0)))
    #expect(healthyService.getQuerySummaryCallCount == 1)

    await client.logout()

    #expect(harness.sessionProvider.createdMockSessions.map(\.invalidateAndCancelCallCount) == [1, 1])
  }

  // MARK: - Cancellation and cleanup bounds

  @Test func cancelledCallerStillSendsTheSessionDeleteFromFreshCleanup() async throws {
    let harness = Harness()
    let server = harness.makeServer("Home")
    harness.publish([server], credentials: [server.id: "secret"])
    let transport = CancellationAwareV6Transport()
    harness.sessionProvider.sessionFactory = { transport }
    let client = OnDemandQueryStatisticsClient(
      connections: try harness.openConnections(),
      serviceFactory: ConcretePiholeServiceFactory(onDemand: ConcreteAuthSessionFactory()),
      sessionProvider: harness.sessionProvider
    )

    let refresh = Task { @MainActor in
      _ = await client.fetchStatistics(scope: .all)
      // Exactly the widget sequence: the refresh task is already cancelled here.
      await client.logout()
    }
    await waitUntil { transport.events.contains("summary") }
    #expect(transport.events.contains("auth"), "the SID exists before the summary is cancelled")
    refresh.cancel()
    await refresh.value

    #expect(
      transport.deleteWasCancelled == false,
      "cleanup must not inherit the cancelled refresh task")
    let events = transport.events
    #expect(events.contains("delete"))
    #expect(!events.contains("delete-cancelled"))
    let deleteIndex = try #require(events.firstIndex(of: "delete"))
    let invalidateIndex = try #require(events.firstIndex(of: "invalidate"))
    #expect(deleteIndex < invalidateIndex, "invalidation must follow the DELETE")
  }

  @Test func logoutIsBoundedWhenACleanupRequestNeverFinishes() async throws {
    let harness = Harness()
    let server = harness.makeServer("Home")
    harness.publish([server], credentials: [server.id: "secret"])
    let service = MockPiholeService(id: server.id, url: server.url, version: server.version)
    var hungLogout: CheckedContinuation<Void, Never>?
    service.logoutHandler = {
      await withCheckedContinuation { hungLogout = $0 }
    }
    harness.serve([server.id: service])
    let session = MockURLSession()
    harness.sessionProvider.sessionFactory = { session }
    var events: [String] = []
    session.invalidateAndCancelHandler = { events.append("invalidate") }
    let client = OnDemandQueryStatisticsClient(
      connections: try harness.openConnections(),
      serviceFactory: harness.factory,
      sessionProvider: harness.sessionProvider,
      cleanupDeadline: {
        // Proves the bound without a real clock: let cleanup start, then elapse.
        await waitUntil { service.logoutCallCount == 1 }
        events.append("deadline")
      }
    )

    _ = await client.fetchStatistics(scope: .all)
    await client.logout()

    #expect(events == ["deadline", "invalidate"], "the budget ends the wait, then transports release")
    #expect(session.invalidateAndCancelCallCount == 1)
    hungLogout?.resume()
  }

  // MARK: - Logout

  @Test func logoutEndsEveryBuiltServiceEvenAfterFailedFetches() async throws {
    let harness = Harness()
    let failing = harness.makeServer("Failing")
    let healthy = harness.makeServer("Healthy")
    harness.publish([failing, healthy], credentials: [failing.id: "a", healthy.id: "b"])
    let failingService = MockPiholeService(id: failing.id, url: failing.url, version: failing.version)
    let healthyService = MockPiholeService(id: healthy.id, url: healthy.url, version: healthy.version)
    failingService.getQuerySummaryStub = .failure(PiholeError.network("offline"))
    harness.serve([failing.id: failingService, healthy.id: healthyService])
    let client = harness.makeClient(connections: try harness.openConnections())

    _ = await client.fetchStatistics(scope: .all)
    #expect(failingService.logoutCallCount == 0, "fetch never logs out on its own")

    await client.logout()
    await client.logout()

    #expect(failingService.logoutCallCount == 1)
    #expect(healthyService.logoutCallCount == 1)
    #expect(harness.sessionProvider.createdMockSessions.map(\.invalidateAndCancelCallCount) == [1, 1])
  }

  @Test func logoutEndsBuiltServicesAfterCancellation() async throws {
    let harness = Harness()
    let server = harness.makeServer("Home")
    harness.publish([server], credentials: [server.id: "secret"])
    let service = MockPiholeService(id: server.id, url: server.url, version: server.version)
    service.getQuerySummaryHandler = {
      try await Task.sleep(for: .seconds(30))
      return QuerySummary(totalQueries: 1, totalBlocked: 0)
    }
    harness.serve([server.id: service])
    let client = harness.makeClient(connections: try harness.openConnections())

    let fetch = Task { @MainActor in await client.fetchStatistics(scope: .all) }
    await waitUntil { service.getQuerySummaryCallCount == 1 }
    fetch.cancel()
    let batch = await fetch.value

    guard case .failure? = batch.results[server.id] else {
      Issue.record("A cancelled fetch must report a per-server failure")
      return
    }
    #expect(service.logoutCallCount == 0)

    await client.logout()

    #expect(service.logoutCallCount == 1)
    #expect(harness.sessionProvider.createdMockSessions.map(\.invalidateAndCancelCallCount) == [1])
  }

  @Test func logoutRequestsFinishBeforeTheirTransportIsInvalidated() async throws {
    let harness = Harness()
    let server = harness.makeServer("Home")
    harness.publish([server], credentials: [server.id: "secret"])
    let service = MockPiholeService(id: server.id, url: server.url, version: server.version)
    harness.serve([server.id: service])
    var events: [String] = []
    let session = MockURLSession()
    harness.sessionProvider.sessionFactory = { session }
    session.invalidateAndCancelHandler = { events.append("invalidate") }
    service.logoutHandler = { events.append("logout") }
    let client = harness.makeClient(connections: try harness.openConnections())

    _ = await client.fetchStatistics(scope: .all)
    await client.logout()

    #expect(events == ["logout", "invalidate"], "logout must still have a transport")
  }

  @Test func logoutDoesNothingWhenNoServiceWasBuilt() async throws {
    let harness = Harness()
    let server = harness.makeServer("Home")
    harness.publish([server], credentials: [server.id: "secret"])
    let client = harness.makeClient(connections: try harness.openConnections())

    await client.logout()

    #expect(harness.factory.buildServiceCallCount == 0)
    #expect(harness.sessionProvider.createdSessions.isEmpty)
  }
}
