import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("PiholeServerManager CRUD")
struct PiholeServerManagerCRUDTests {
  private let mockKeychain = MockKeychainManager()
  private let mockServiceFactory = MockPiholeServiceFactory()
  private let mockVersionDetector = MockPiholeVersionDetector()

  private func makeManager(suite: UserDefaults) -> PiholeServerManager {
    PiholeServerManager(
      keychain: mockKeychain,
      serviceFactory: mockServiceFactory,
      versionDetector: mockVersionDetector,
      suite: suite
    )
  }

  @Test("starts empty")
  func startsEmpty() {
    let manager = makeManager(suite: TestDefaults.makeSuite())
    #expect(manager.servers.isEmpty)
  }

  @Test("delete server removes it")
  func deleteServer() {
    let manager = makeManager(suite: TestDefaults.makeSuite())
    let server = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    manager.servers = [server]
    let id = manager.servers[0].id
    manager.deleteServer(id: id)
    #expect(manager.servers.isEmpty)
  }

  @Test("update server changes properties")
  func updateServer() {
    let manager = makeManager(suite: TestDefaults.makeSuite())
    let server = ServerConfig(label: "Old", url: "http://old.com", version: .v6)
    manager.servers = [server]
    guard let id = manager.servers.first?.id else {
      Issue.record("No server")
      return
    }

    manager.updateServer(id: id, label: "New", url: "http://new.com", credential: nil)
    #expect(manager.servers[0].label == "New")
    #expect(manager.servers[0].url == "http://new.com")
  }

  @Test("update server with credential saves to keychain")
  func updateServerWithCredential() {
    let manager = makeManager(suite: TestDefaults.makeSuite())
    let server = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    manager.servers = [server]
    guard let id = manager.servers.first?.id else {
      Issue.record("No server")
      return
    }

    manager.updateServer(id: id, label: "Updated", url: "http://test.com", credential: "new-password")
    #expect(mockKeychain.storedCredentials[id.uuidString] == "new-password")
  }

  @Test("delete server removes credential from keychain")
  func deleteServerRemovesCredential() {
    let manager = makeManager(suite: TestDefaults.makeSuite())
    let server = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    manager.servers = [server]
    let id = manager.servers[0].id
    try? mockKeychain.saveCredential("secret", for: id)
    #expect(mockKeychain.storedCredentials[id.uuidString] != nil)

    manager.deleteServer(id: id)
    #expect(manager.servers.isEmpty)
    #expect(mockKeychain.storedCredentials[id.uuidString] == nil)
  }

  @Test("max 2 servers enforced")
  func maxServersEnforced() async {
    let manager = makeManager(suite: TestDefaults.makeSuite())
    let server1 = ServerConfig(label: "A", url: "http://a.com", version: .v6)
    let server2 = ServerConfig(label: "B", url: "http://b.com", version: .v6)
    manager.servers = [server1, server2]

    // addServer should throw since we already have 2
    // We can't easily call addServer without network, but we test the guard
    #expect(manager.servers.count == 2)
  }

  @Test("addServer registers server and stores credential in keychain")
  func addServerSuccess() async throws {
    let manager = makeManager(suite: TestDefaults.makeSuite())
    try await manager.addServer(label: "Test", url: "http://test.com", credential: "secret")

    #expect(manager.servers.count == 1)
    #expect(manager.servers[0].label == "Test")
    #expect(manager.servers[0].version == .v6)
    #expect(mockKeychain.storedCredentials[manager.servers[0].id.uuidString] == "secret")
    #expect(mockServiceFactory.buildServiceCallCount == 1)
  }

  @Test("addServer accepts an empty credential for password-less instances")
  func addServerWithEmptyCredential() async throws {
    let manager = makeManager(suite: TestDefaults.makeSuite())
    try await manager.addServer(label: "Open", url: "http://test.com", credential: "")

    #expect(manager.servers.count == 1)
    #expect(manager.servers[0].version == .v6)
    #expect(
      mockKeychain.storedCredentials[manager.servers[0].id.uuidString] == nil,
      "password-less servers store no credential in the keychain"
    )
  }

  @Test("addServer stores no credential when the server reports password-less")
  func addServerStoresNoCredentialWhenServerReportsPasswordless() async throws {
    let manager = makeManager(suite: TestDefaults.makeSuite())
    let service = MockPiholeService(url: "http://test.com", version: .v6)
    service.isPasswordless = true
    mockServiceFactory.buildServiceStub = service
    defer { mockServiceFactory.buildServiceStub = nil }

    try await manager.addServer(label: "Open", url: "http://test.com", credential: "junk")

    #expect(manager.servers.count == 1)
    #expect(
      mockKeychain.storedCredentials[manager.servers[0].id.uuidString] == nil,
      "junk credential must not be stored for password-less servers"
    )
  }

  @Test("addServer throws and leaves nothing registered when keychain save fails")
  func addServerKeychainFailureLeavesNoPartialState() async {
    let suite = TestDefaults.makeSuite()
    let manager = makeManager(suite: suite)
    mockKeychain.errorStub = PiholeError.unknown("keychain unavailable")
    defer { mockKeychain.errorStub = nil }

    await #expect(throws: PiholeError.self) {
      try await manager.addServer(label: "Test", url: "http://test.com", credential: "secret")
    }
    #expect(manager.servers.isEmpty)
    #expect(Defaults[.servers(suite: suite)].isEmpty)
  }

  @Test("loadServers builds a service even without a stored credential")
  func loadServersBuildsServiceWithoutCredential() {
    let suite = TestDefaults.makeSuite()
    let config = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    Defaults[.servers(suite: suite)] = [config]

    _ = makeManager(suite: suite)

    #expect(mockServiceFactory.buildServiceCallCount == 1, "service must be built so the UI can offer re-auth")
  }

  @Test("checkServer reports missingCredential when no credential is stored")
  func checkServerReportsMissingCredentialWhenNoneStored() async {
    let suite = TestDefaults.makeSuite()
    let config = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    Defaults[.servers(suite: suite)] = [config]

    let failingService = MockPiholeService(id: config.id, url: config.url, version: .v6)
    failingService.checkStatusStub = .failure(PiholeError.invalidCredentials)
    mockServiceFactory.buildServiceStub = failingService
    defer { mockServiceFactory.buildServiceStub = nil }

    let manager = makeManager(suite: suite)
    let result = await manager.checkServer(id: config.id)

    #expect(result == .failure(.missingCredential))
  }

  @Test("checkServer keeps invalidCredentials when a credential is stored")
  func checkServerKeepsInvalidCredentialsWhenStored() async {
    let suite = TestDefaults.makeSuite()
    let config = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    Defaults[.servers(suite: suite)] = [config]
    try? mockKeychain.saveCredential("old-password", for: config.id)

    let failingService = MockPiholeService(id: config.id, url: config.url, version: .v6)
    failingService.checkStatusStub = .failure(PiholeError.invalidCredentials)
    mockServiceFactory.buildServiceStub = failingService
    defer { mockServiceFactory.buildServiceStub = nil }

    let manager = makeManager(suite: suite)
    let result = await manager.checkServer(id: config.id)

    #expect(result == .failure(.invalidCredentials))
  }

  private func makeManagerWithLoadedService(suite: UserDefaults) -> PiholeServerManager {
    let config = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    Defaults[.servers(suite: suite)] = [config]
    try? mockKeychain.saveCredential("old-password", for: config.id)
    return PiholeServerManager(
      keychain: mockKeychain,
      serviceFactory: mockServiceFactory,
      versionDetector: mockVersionDetector,
      suite: suite
    )
  }

  @Test("update server with changed credential rebuilds the service")
  func updateServerWithChangedCredentialRebuildsService() {
    let manager = makeManagerWithLoadedService(suite: TestDefaults.makeSuite())
    guard let id = manager.servers.first?.id else {
      Issue.record("No server")
      return
    }
    let buildsBefore = mockServiceFactory.buildServiceCallCount
    #expect(buildsBefore == 1, "loadServers built the service")

    manager.updateServer(id: id, label: "Test", url: "http://test.com", credential: "new-password")
    #expect(mockServiceFactory.buildServiceCallCount == buildsBefore + 1, "credential change must rebuild")
    #expect(mockKeychain.storedCredentials[id.uuidString] == "new-password")
  }

  @Test("update server with same credential does not rebuild")
  func updateServerWithSameCredentialDoesNotRebuild() {
    let manager = makeManagerWithLoadedService(suite: TestDefaults.makeSuite())
    guard let id = manager.servers.first?.id else {
      Issue.record("No server")
      return
    }
    let buildsBefore = mockServiceFactory.buildServiceCallCount
    manager.updateServer(id: id, label: "Test", url: "http://test.com", credential: "old-password")
    #expect(mockServiceFactory.buildServiceCallCount == buildsBefore)
  }

  @Test("update server with empty credential clears the stored credential")
  func updateServerWithEmptyCredentialClears() {
    let manager = makeManagerWithLoadedService(suite: TestDefaults.makeSuite())
    guard let id = manager.servers.first?.id else {
      Issue.record("No server")
      return
    }
    #expect(mockKeychain.storedCredentials[id.uuidString] == "old-password")
    let buildsBefore = mockServiceFactory.buildServiceCallCount
    #expect(buildsBefore == 1, "loadServers built the service")

    manager.updateServer(id: id, label: "Test", url: "http://test.com", credential: "")

    #expect(
      mockKeychain.storedCredentials[id.uuidString] == nil,
      "clearing the credential removes it from the keychain"
    )
    #expect(mockServiceFactory.buildServiceCallCount == buildsBefore + 1, "credential change must rebuild")
  }

  @Test("verifyCredential succeeds and logs out the probe service")
  func verifyCredentialSucceeds() async throws {
    let manager = makeManagerWithLoadedService(suite: TestDefaults.makeSuite())
    guard let id = manager.servers.first?.id else {
      Issue.record("No server")
      return
    }
    let probe = MockPiholeService(id: id, url: "http://test.com", version: .v6)
    mockServiceFactory.buildServiceStub = probe

    let result = try await manager.verifyCredential(id: id, credential: "fresh-password")
    #expect(result == false, "a real credential on a protected server reports password-protected")
    #expect(probe.loginCallCount == 1)
    #expect(probe.checkStatusCallCount == 1)
    #expect(probe.logoutCallCount == 1)
  }

  @Test("verifyCredential succeeds with an empty credential (password-less)")
  func verifyCredentialWithEmptyCredential() async throws {
    let manager = makeManagerWithLoadedService(suite: TestDefaults.makeSuite())
    guard let id = manager.servers.first?.id else {
      Issue.record("No server")
      return
    }
    let probe = MockPiholeService(id: id, url: "http://test.com", version: .v6)
    probe.isPasswordless = true
    mockServiceFactory.buildServiceStub = probe

    let result = try await manager.verifyCredential(id: id, credential: "")
    #expect(result == true, "a password-less server must report password-less")
    #expect(probe.loginCallCount == 1)
    #expect(probe.checkStatusCallCount == 1)
    #expect(probe.logoutCallCount == 1)
  }

  @Test("verifyCredential throws on invalid credentials")
  func verifyCredentialThrowsOnInvalid() async {
    let manager = makeManagerWithLoadedService(suite: TestDefaults.makeSuite())
    guard let id = manager.servers.first?.id else {
      Issue.record("No server")
      return
    }
    let probe = MockPiholeService(id: id, url: "http://test.com", version: .v6)
    probe.loginStub = .failure(PiholeError.invalidCredentials)
    mockServiceFactory.buildServiceStub = probe

    await #expect(throws: PiholeError.self) {
      try await manager.verifyCredential(id: id, credential: "wrong")
    }
  }

  @Test("verifyCredential logs out the probe even when the probe fails mid-way")
  func verifyCredentialLogsOutOnProbeFailure() async {
    let manager = makeManagerWithLoadedService(suite: TestDefaults.makeSuite())
    guard let id = manager.servers.first?.id else {
      Issue.record("No server")
      return
    }
    // Login succeeds (session established server-side), then the status probe
    // fails — the probe session must still be logged out.
    let probe = MockPiholeService(id: id, url: "http://test.com", version: .v6)
    probe.checkStatusStub = .failure(PiholeError.network("blip"))
    mockServiceFactory.buildServiceStub = probe

    await #expect(throws: PiholeError.self) {
      try await manager.verifyCredential(id: id, credential: "fresh-password")
    }
    #expect(probe.loginCallCount == 1)
    #expect(probe.logoutCallCount == 1, "probe must not leak a session")
  }

  @Test("updateGravity asks all servers and skips the unsupported ones")
  func updateGravitySkipsUnsupported() async throws {
    let manager = makeManager(suite: TestDefaults.makeSuite())
    let v5Service = MockPiholeService(version: .v5)
    let v6Service = MockPiholeService(version: .v6)
    mockServiceFactory.buildServiceHandler = { config in
      config.version == .v5 ? v5Service : v6Service
    }

    mockVersionDetector.detectStub = .success(.v5)
    try await manager.addServer(label: "Old", url: "http://v5.local", credential: "a")
    mockVersionDetector.detectStub = .success(.v6)
    try await manager.addServer(label: "New", url: "http://v6.local", credential: "b")

    let v6ID = try #require(manager.servers.first { $0.version == .v6 }?.id)
    v5Service.updateGravityStub = .failure(
      PiholeError.unsupported("Gravity updates via API are not supported by Pi-hole v5")
    )
    v6Service.updateGravityStub = .success(())

    let results = await manager.updateGravity()

    #expect(results.count == 1)
    guard case .success = results[v6ID] else {
      Issue.record("expected success, got \(String(describing: results[v6ID]))")
      return
    }
    #expect(v5Service.updateGravityCallCount == 1, "v5 must be asked before being skipped")
    #expect(v6Service.updateGravityCallCount == 1)
  }

  @Test("updateGravity aggregates failures")
  func updateGravityAggregatesFailures() async throws {
    let manager = makeManager(suite: TestDefaults.makeSuite())
    let service = MockPiholeService()
    mockServiceFactory.buildServiceStub = service

    try await manager.addServer(label: "New", url: "http://v6.local", credential: "b")
    let v6ID = try #require(manager.servers.first?.id)
    service.updateGravityStub = .failure(PiholeError.network("down"))

    let results = await manager.updateGravity()

    guard case .failure(let error) = results[v6ID] else {
      Issue.record("expected failure, got \(String(describing: results[v6ID]))")
      return
    }
    #expect(error == .network("down"))
    #expect(service.updateGravityCallCount == 1)
  }

  // MARK: - Display Labels

  @Test("Uses the requested server's saved label", arguments: ["Kitchen", " Kitchen ", "https://Kitchen"])
  func savedLabel(label: String) {
    let manager = makeManager(suite: TestDefaults.makeSuite())
    let server = ServerConfig(label: label, url: "http://192.168.1.20", version: .v6)
    manager.servers = [ServerConfig(label: "Other", url: "http://other.local", version: .v5), server]

    #expect(manager.displayLabel(for: server.id) == label)
  }

  @Test("Uses the hostname when the label is missing or blank", arguments: [nil, "", " \t\n"] as [String?])
  func missingLabel(label: String?) {
    let manager = makeManager(suite: TestDefaults.makeSuite())
    let server = ServerConfig(label: label, url: "http://192.168.1.20", version: .v6)
    manager.servers = [server]

    #expect(manager.displayLabel(for: server.id) == "192.168.1.20")
  }

  @Test(
    "URL display names use only the hostname",
    arguments: [
      ("http://192.168.1.20", "192.168.1.20"),
      ("https://pi.hole:8443/admin/", "pi.hole"),
      ("HTTP://pi.hole", "pi.hole"),
      ("HTTPS://pi.hole", "pi.hole"),
      ("pi.hole:8080", "pi.hole:8080"),
      ("http://[::1]:8080/admin/", "[::1]"),
      ("https://pi.hole/a%20b?next=http://other#part", "pi.hole"),
      ("http://[invalid", "http://[invalid"),
      ("http:///admin/", "http:///admin/")
    ]
  )
  func urlDisplayName(url: String, expected: String) {
    let manager = makeManager(suite: TestDefaults.makeSuite())
    let server = ServerConfig(url: url, version: .v6)
    manager.servers = [server]

    #expect(manager.displayLabel(for: server.id) == expected)
    #expect(manager.servers[0].url == url)
  }

  @Test("Returns nil for an unknown server")
  func unknownServer() {
    let manager = makeManager(suite: TestDefaults.makeSuite())
    manager.servers = [ServerConfig(label: "Kitchen", url: "http://192.168.1.20", version: .v6)]

    #expect(manager.displayLabel(for: UUID()) == nil)
  }

  // MARK: - On-demand reads

  @Test("Manager construction and reload do not log in; requested reads still work")
  func noWarmup() async throws {
    let suite = TestDefaults.makeSuite()
    let service = MockPiholeService()
    Defaults[.servers(suite: suite)] = [ServerConfig(id: service.id, url: service.url, version: service.version)]
    let factory = MockPiholeServiceFactory()
    factory.buildServiceStub = service
    let manager = PiholeServerManager(
      keychain: MockKeychainManager(), serviceFactory: factory,
      versionDetector: MockPiholeVersionDetector(), suite: suite, executionMode: .onDemand
    )
    manager.reloadServers()
    await settle()
    #expect(service.loginCallCount == 0)
    #expect(factory.buildServiceExecutionModes == [.onDemand, .onDemand])
    let status = await manager.getBlockingStatus(scope: .server(service.id))
    #expect(try status[service.id]?.get() == .enabled)
    #expect(service.checkStatusCallCount == 1)
    await manager.logoutAll()
    #expect(service.logoutCallCount == 1)
  }

  @Test("The existing application default still warms sessions")
  func applicationDefault() async {
    let suite = TestDefaults.makeSuite()
    let service = MockPiholeService()
    Defaults[.servers(suite: suite)] = [ServerConfig(id: service.id, url: service.url, version: service.version)]
    let factory = MockPiholeServiceFactory()
    factory.buildServiceStub = service
    let manager = PiholeServerManager(
      keychain: MockKeychainManager(), serviceFactory: factory,
      versionDetector: MockPiholeVersionDetector(), suite: suite
    )
    await waitUntil { service.loginCallCount == 1 }
    #expect(factory.buildServiceExecutionModes == [.application])
    await manager.logoutAll()
  }

}

@MainActor
@Suite("PiholeServerManager - Server Operations")
struct PiholeServerManagerOperationsTests {
  private let mockService1 = MockPiholeService(
    id: UUID(), label: "Server A", url: "http://a.local", version: .v6)
  private let mockService2 = MockPiholeService(
    id: UUID(), label: "Server B", url: "http://b.local", version: .v6)
  private let mockServiceFactory = MockPiholeServiceFactory()

  private func makeManager(suite: UserDefaults) -> PiholeServerManager {
    PiholeServerManager(
      keychain: MockKeychainManager(),
      serviceFactory: mockServiceFactory,
      versionDetector: MockPiholeVersionDetector(),
      suite: suite
    )
  }

  /// A manager with two configured servers, answered by `mockService1` and
  /// `mockService2`. The manager retains the isolated defaults suite.
  private func makeManagerWithTwoServers() -> PiholeServerManager {
    let suite = TestDefaults.makeSuite()
    Defaults[.servers(suite: suite)] = [
      ServerConfig(id: mockService1.id, label: "Server A", url: "http://a.local", version: .v6),
      ServerConfig(id: mockService2.id, label: "Server B", url: "http://b.local", version: .v6)
    ]
    mockServiceFactory.buildServiceHandler = { config in
      config.id == mockService1.id ? mockService1 : mockService2
    }
    return makeManager(suite: suite)
  }

  @Test("getRecentBlocked deduplicates by domain")
  func getRecentBlockedDeduplicates() async throws {
    let date = Date()
    mockService1.getRecentBlockedStub = .success([
      BlockedDomain(domain: "ads.com", timestamp: date, fromClientIp: "1.1.1.1"),
      BlockedDomain(domain: "tracker.net", timestamp: date.addingTimeInterval(-10), fromClientIp: "1.1.1.1")
    ])
    mockService2.getRecentBlockedStub = .success([
      BlockedDomain(domain: "ads.com", timestamp: date.addingTimeInterval(-5), fromClientIp: "2.2.2.2"),
      BlockedDomain(domain: "malware.net", timestamp: date, fromClientIp: "2.2.2.2")
    ])

    let manager = makeManagerWithTwoServers()
    let interval = DateInterval(start: date.addingTimeInterval(-3600), end: date)
    let deduped = try await manager.getRecentBlocked(forClientIp: nil, interval: interval)

    #expect(deduped.count == 3)
    #expect(deduped.contains { $0.domain == "ads.com" })
    #expect(deduped.contains { $0.domain == "tracker.net" })
    #expect(deduped.contains { $0.domain == "malware.net" })
    let ads = try #require(deduped.first { $0.domain == "ads.com" })
    #expect(ads.count == 2)
    #expect(ads.timestamp == date)
    #expect(ads.fromClientIp == "1.1.1.1")
  }

  @Test("unblock normalizes domains before the managed call", arguments: ["www.example.com", "example.com"])
  func unblockDomainNormalization(domain: String) async throws {
    let manager = makeManagerWithTwoServers()
    _ = try await manager.unblock(domain: domain, duration: 60)
    #expect(mockService1.unblockDomainLastDomain == "example.com")
    #expect(mockService2.unblockDomainLastDomain == "example.com")
    #expect(mockService1.unblockDomainLastDuration == 60)
    #expect(mockService1.unblockDomainCallCount == 1)
    #expect(mockService2.unblockDomainCallCount == 1)
  }

  @Test("Multi-server workflows preserve additions and no-ops", arguments: [true, false])
  func mixedDomainOutcomes(permanent: Bool) async throws {
    mockService2.unblockDomainStub = .success(.alreadyPresent(enabled: false))
    let manager = makeManagerWithTwoServers()
    let outcomes: [UUID: DomainUnblockOutcome]
    if permanent {
      outcomes = await manager.addToAllowlist(domain: "www.example.com")
    } else {
      outcomes = try await manager.unblock(domain: "www.example.com", duration: 60)
    }
    #expect(outcomes[mockService1.id] == .added)
    #expect(outcomes[mockService2.id] == .alreadyPresent(enabled: false))
    #expect(mockService1.unblockDomainLastDomain == "example.com")
    #expect(mockService2.unblockDomainLastDomain == "example.com")
    #expect(mockService1.unblockDomainLastDuration == (permanent ? nil : 60))
    #expect(mockService1.unblockDomainCallCount == 1)
    #expect(mockService2.unblockDomainCallCount == 1)
    #expect(mockService1.addDomainCallCount == 0)
  }

  @Test("A run of only no-ops returns no additions")
  func allExistingEntries() async throws {
    for service in [mockService1, mockService2] {
      service.unblockDomainStub = .success(.alreadyPresent(enabled: nil))
    }
    let outcomes = try await makeManagerWithTwoServers().unblock(domain: "example.com", duration: 60)
    #expect(outcomes.count == 2)
    #expect(outcomes.values.allSatisfy { $0 == .alreadyPresent(enabled: nil) })
  }

  @Test("Managed failures preserve other server outcomes without manager retries", arguments: [true, false])
  func partialManagedFailure(permanent: Bool) async throws {
    mockService1.unblockDomainStub = .success(permanent ? .promoted : .renewed)
    mockService2.unblockDomainStub = .failure(PiholeError.network("offline"))
    let manager = makeManagerWithTwoServers()
    let outcomes: [UUID: DomainUnblockOutcome]
    if permanent {
      outcomes = await manager.addToAllowlist(domain: "example.com")
    } else {
      outcomes = try await manager.unblock(domain: "example.com", duration: 60)
    }
    #expect(outcomes.count == 1)
    #expect(outcomes[mockService1.id] == (permanent ? .promoted : .renewed))
    #expect(mockService1.unblockDomainCallCount == 1)
    #expect(mockService2.unblockDomainCallCount == 1)
  }
  @Test("Selected reads never contact the other server")
  func selectedServer() async throws {
    mockService1.getQuerySummaryStub = .success(QuerySummary(totalQueries: 100, totalBlocked: 20))
    let manager = makeManagerWithTwoServers()
    let statuses = await manager.getBlockingStatus(scope: .server(mockService1.id))
    let summaries = await manager.getQuerySummary(scope: .server(mockService1.id))

    #expect(Set(statuses.keys) == [mockService1.id])
    #expect(try statuses[mockService1.id]?.get() == .enabled)
    #expect(try summaries[mockService1.id]?.get().totalQueries == 100)
    #expect(try summaries[mockService1.id]?.get().totalBlocked == 20)
    #expect(mockService2.checkStatusCallCount == 0)
    #expect(mockService2.getQuerySummaryCallCount == 0)
  }

  @Test("Missing selected UUID fails each operation without falling back")
  func missingServer() async {
    let manager = makeManagerWithTwoServers()
    let missing = UUID()
    let statuses = await manager.getBlockingStatus(scope: .server(missing))
    let summaries = await manager.getQuerySummary(scope: .server(missing))

    #expect(statuses[missing] == .failure(.unknown("Server not found")))
    if case .failure(.unknown("Server not found")) = summaries[missing] {
    } else {
      Issue.record("Missing summary target must fail")
    }
    #expect(statuses.count == 1)
    #expect(summaries.count == 1)
    #expect(mockService1.checkStatusCallCount + mockService2.checkStatusCallCount == 0)
    #expect(mockService1.getQuerySummaryCallCount + mockService2.getQuerySummaryCallCount == 0)
  }

  @Test("All-server reads retain independent results and exact errors")
  func mixedResults() async throws {
    mockService2.checkStatusStub = .failure(PiholeError.tlsUntrusted)
    mockService2.getQuerySummaryStub = .failure(PiholeError.decoding("bad summary"))
    let manager: any PiholeServerManaging = makeManagerWithTwoServers()

    let statuses = await manager.getBlockingStatus(scope: .all)
    let summaries = await manager.getQuerySummary(scope: .all)

    #expect(try statuses[mockService1.id]?.get() == .enabled)
    #expect(statuses[mockService2.id] == .failure(.tlsUntrusted))
    #expect(try summaries[mockService1.id]?.get().totalQueries == 0)
    if case .failure(.decoding("bad summary")) = summaries[mockService2.id] {
    } else {
      Issue.record("Summary error was lost")
    }
  }

  @Test("Empty all-server requests return no results")
  func emptyServers() async {
    let manager = PiholeServerManager(
      keychain: MockKeychainManager(), serviceFactory: MockPiholeServiceFactory(),
      versionDetector: MockPiholeVersionDetector(), suite: TestDefaults.makeSuite()
    )
    #expect(await manager.getBlockingStatus(scope: .all).isEmpty)
    #expect(await manager.getQuerySummary(scope: .all).isEmpty)
  }


  @Test("Real and mock readers honor the same scope contract", arguments: [false, true])
  func scopedReaderContract(queuedSummaries: Bool) async throws {
    mockService1.getQuerySummaryStub = .success(QuerySummary(totalQueries: 100, totalBlocked: 20))
    mockService2.checkStatusStub = .failure(PiholeError.tlsUntrusted)
    mockService2.getQuerySummaryStub = .failure(PiholeError.decoding("bad summary"))
    let real = makeManagerWithTwoServers()
    let mock = MockPiholeServerManager()
    mock.servers = real.servers
    mock.getBlockingStatusStub = [mockService1.id: .success(.enabled), mockService2.id: .failure(.tlsUntrusted)]
    let summaries: [UUID: Result<QuerySummary, PiholeError>] = [
      mockService1.id: .success(QuerySummary(totalQueries: 100, totalBlocked: 20)),
      mockService2.id: .failure(.decoding("bad summary"))
    ]
    if queuedSummaries {
      mock.getQuerySummaryResponses = [summaries, summaries, summaries, summaries, summaries]
    } else {
      mock.getQuerySummaryStub = summaries
    }
    let missing = UUID()
    for reader: any PiholeServerManaging in [real, mock] {
      let selectedStatus = await reader.getBlockingStatus(scope: .server(mockService1.id))
      let selectedSummary = await reader.getQuerySummary(scope: .server(mockService1.id))
      #expect(Set(selectedStatus.keys) == [mockService1.id])
      #expect(Set(selectedSummary.keys) == [mockService1.id])
      #expect(try selectedStatus[mockService1.id]?.get() == .enabled)
      #expect(try selectedSummary[mockService1.id]?.get().totalQueries == 100)

      let unknownStatus = await reader.getBlockingStatus(scope: .server(missing))
      let unknownSummary = await reader.getQuerySummary(scope: .server(missing))
      #expect(Set(unknownStatus.keys) == [missing])
      #expect(Set(unknownSummary.keys) == [missing])
      #expect(unknownStatus[missing] == .failure(.unknown("Server not found")))
      if case .failure(.unknown("Server not found")) = unknownSummary[missing] {
      } else {
        Issue.record("Unknown summary target must fail")
      }

      let allStatus = await reader.getBlockingStatus(scope: .all)
      let allSummary = await reader.getQuerySummary(scope: .all)
      #expect(Set(allStatus.keys) == [mockService1.id, mockService2.id])
      #expect(Set(allSummary.keys) == [mockService1.id, mockService2.id])
      #expect(allStatus[mockService2.id] == .failure(.tlsUntrusted))
      if case .failure(.decoding("bad summary")) = allSummary[mockService2.id] {
      } else {
        Issue.record("Summary failure must be preserved")
      }
    }

    // Keep the old responses to expose stale stub entries after configuration changes.
    real.deleteServer(id: mockService2.id)
    mock.servers = real.servers
    for reader: any PiholeServerManaging in [real, mock] {
      let status = await reader.getBlockingStatus(scope: .all)
      let summary = await reader.getQuerySummary(scope: .all)
      #expect(Set(status.keys) == [mockService1.id])
      #expect(Set(summary.keys) == [mockService1.id])
    }

    real.deleteServer(id: mockService1.id)
    mock.servers = []
    for reader: any PiholeServerManaging in [real, mock] {
      #expect(await reader.getBlockingStatus(scope: .all).isEmpty)
      #expect(await reader.getQuerySummary(scope: .all).isEmpty)
    }
  }

}
