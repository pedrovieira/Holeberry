import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("PiholeServerManager CRUD")
struct PiholeServerManagerCRUDTests {
  private let storage = MockAppStorage()
  private let mockServiceFactory = MockPiholeServiceFactory()
  private let mockVersionDetector = MockPiholeVersionDetector()

  private func makeManager() -> PiholeServerManager {
    PiholeServerManager(
      storage: storage,
      serviceFactory: mockServiceFactory,
      versionDetector: mockVersionDetector
    )
  }

  @Test("starts empty")
  func startsEmpty() {
    let manager = makeManager()
    #expect(manager.servers.isEmpty)
  }

  @Test("delete server removes it")
  func deleteServer() {
    let manager = makeManager()
    let server = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    manager.servers = [server]
    let id = manager.servers[0].id
    manager.deleteServer(id: id)
    #expect(manager.servers.isEmpty)
  }

  @Test("update server changes properties")
  func updateServer() {
    let manager = makeManager()
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
    let manager = makeManager()
    let server = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    manager.servers = [server]
    guard let id = manager.servers.first?.id else {
      Issue.record("No server")
      return
    }

    manager.updateServer(id: id, label: "Updated", url: "http://test.com", credential: "new-password")
    #expect(storage.credentials[id] == "new-password")
  }

  @Test("delete server removes credential from keychain")
  func deleteServerRemovesCredential() {
    let manager = makeManager()
    let server = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    manager.servers = [server]
    let id = manager.servers[0].id
    storage.credentials[id] = "secret"
    #expect(storage.credentials[id] != nil)

    manager.deleteServer(id: id)
    #expect(manager.servers.isEmpty)
    #expect(storage.credentials[id] == nil)
  }

  @Test("max 2 servers enforced")
  func maxServersEnforced() async {
    let manager = makeManager()
    let server1 = ServerConfig(label: "A", url: "http://a.com", version: .v6)
    let server2 = ServerConfig(label: "B", url: "http://b.com", version: .v6)
    manager.servers = [server1, server2]
    let buildsBefore = mockServiceFactory.buildServiceCallCount

    let error = await #expect(throws: PiholeError.self) {
      try await manager.addServer(label: "C", url: "http://c.com", credential: "secret")
    }

    #expect(error == .unknown("Maximum of 2 Pi-hole instances allowed"))
    #expect(manager.servers.map(\.id) == [server1.id, server2.id])
    #expect(
      mockServiceFactory.buildServiceCallCount == buildsBefore,
      "the limit is enforced before any version detection or service build")
    #expect(storage.servers.isEmpty, "the rejected add persists nothing")
  }

  @Test("addServer registers server and stores credential in keychain")
  func addServerSuccess() async throws {
    let manager = makeManager()
    try await manager.addServer(label: "Test", url: "http://test.com", credential: "secret")

    #expect(manager.servers.count == 1)
    #expect(manager.servers[0].label == "Test")
    #expect(manager.servers[0].version == .v6)
    #expect(storage.credentials[manager.servers[0].id] == "secret")
    #expect(mockServiceFactory.buildServiceCallCount == 1)
  }

  @Test("addServer accepts an empty credential for password-less instances")
  func addServerWithEmptyCredential() async throws {
    let manager = makeManager()
    try await manager.addServer(label: "Open", url: "http://test.com", credential: "")

    #expect(manager.servers.count == 1)
    #expect(manager.servers[0].version == .v6)
    #expect(
      storage.credentials[manager.servers[0].id] == nil,
      "password-less servers store no credential in the keychain"
    )
  }

  @Test("addServer stores no credential when the server reports password-less")
  func addServerStoresNoCredentialWhenServerReportsPasswordless() async throws {
    let manager = makeManager()
    let service = MockPiholeService(url: "http://test.com", version: .v6)
    service.isPasswordless = true
    mockServiceFactory.buildServiceStub = service
    defer { mockServiceFactory.buildServiceStub = nil }

    try await manager.addServer(label: "Open", url: "http://test.com", credential: "junk")

    #expect(manager.servers.count == 1)
    #expect(
      storage.credentials[manager.servers[0].id] == nil,
      "junk credential must not be stored for password-less servers"
    )
  }

  @Test("addServer throws and leaves nothing registered when credential save fails")
  func addServerKeychainFailureLeavesNoPartialState() async {
    let manager = makeManager()
    storage.saveCredentialStub = .failure(PiholeError.unknown("keychain unavailable"))

    await #expect(throws: PiholeError.self) {
      try await manager.addServer(label: "Test", url: "http://test.com", credential: "secret")
    }
    #expect(manager.servers.isEmpty)
    #expect(storage.servers.isEmpty)
    #expect(storage.credentials.isEmpty)
  }

  @Test("loadServers builds a service even without a stored credential")
  func loadServersBuildsServiceWithoutCredential() {
    let config = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    storage.servers = [config]

    _ = makeManager()

    #expect(mockServiceFactory.buildServiceCallCount == 1, "service must be built so the UI can offer re-auth")
    #expect(mockServiceFactory.buildServiceLastCredential == "", "an absent credential becomes an empty one")
  }

  @Test("loadServers builds a service with an empty credential when the read throws")
  func loadServersBuildsServiceWhenCredentialReadThrows() {
    let config = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    storage.servers = [config]
    storage.credentials[config.id] = "stored"
    storage.readCredentialStub = .failure(PiholeError.unknown("keychain unreadable"))

    _ = makeManager()

    #expect(mockServiceFactory.buildServiceCallCount == 1)
    #expect(
      mockServiceFactory.buildServiceLastCredential == "",
      "an unreadable credential still yields a service so the UI can offer re-authentication")
  }

  @Test("loadServers forwards the injected storage instance")
  func loadServersForwardsStorage() {
    storage.servers = [ServerConfig(label: "Test", url: "http://test.com", version: .v6)]

    _ = makeManager()

    #expect(isSameStorageInstance(mockServiceFactory.buildServiceLastStorage, storage))
  }

  @Test("checkServer reports missingCredential when no credential is stored")
  func checkServerReportsMissingCredentialWhenNoneStored() async {
    let config = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    storage.servers = [config]

    let failingService = MockPiholeService(id: config.id, url: config.url, version: .v6)
    failingService.checkStatusStub = .failure(PiholeError.invalidCredentials)
    mockServiceFactory.buildServiceStub = failingService
    defer { mockServiceFactory.buildServiceStub = nil }

    let manager = makeManager()
    let result = await manager.checkServer(id: config.id)

    #expect(result == .failure(.missingCredential))
  }

  @Test("checkServer keeps invalidCredentials when a credential is stored")
  func checkServerKeepsInvalidCredentialsWhenStored() async {
    let config = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    storage.servers = [config]
    storage.credentials[config.id] = "old-password"

    let failingService = MockPiholeService(id: config.id, url: config.url, version: .v6)
    failingService.checkStatusStub = .failure(PiholeError.invalidCredentials)
    mockServiceFactory.buildServiceStub = failingService
    defer { mockServiceFactory.buildServiceStub = nil }

    let manager = makeManager()
    let result = await manager.checkServer(id: config.id)

    #expect(result == .failure(.invalidCredentials))
  }

  private func makeManagerWithLoadedService() -> PiholeServerManager {
    let config = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    storage.servers = [config]
    storage.credentials[config.id] = "old-password"
    return PiholeServerManager(
      storage: storage,
      serviceFactory: mockServiceFactory,
      versionDetector: mockVersionDetector
    )
  }

  @Test("update server with changed credential rebuilds the service")
  func updateServerWithChangedCredentialRebuildsService() {
    let manager = makeManagerWithLoadedService()
    guard let id = manager.servers.first?.id else {
      Issue.record("No server")
      return
    }
    let buildsBefore = mockServiceFactory.buildServiceCallCount
    #expect(buildsBefore == 1, "loadServers built the service")

    manager.updateServer(id: id, label: "Test", url: "http://test.com", credential: "new-password")
    #expect(mockServiceFactory.buildServiceCallCount == buildsBefore + 1, "credential change must rebuild")
    #expect(storage.credentials[id] == "new-password")
  }

  @Test("update server with same credential does not rebuild")
  func updateServerWithSameCredentialDoesNotRebuild() {
    let manager = makeManagerWithLoadedService()
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
    let manager = makeManagerWithLoadedService()
    guard let id = manager.servers.first?.id else {
      Issue.record("No server")
      return
    }
    #expect(storage.credentials[id] == "old-password")
    let buildsBefore = mockServiceFactory.buildServiceCallCount
    #expect(buildsBefore == 1, "loadServers built the service")

    manager.updateServer(id: id, label: "Test", url: "http://test.com", credential: "")

    #expect(
      storage.credentials[id] == nil,
      "clearing the credential removes it from the keychain"
    )
    #expect(mockServiceFactory.buildServiceCallCount == buildsBefore + 1, "credential change must rebuild")
    #expect(storage.deleteCredentialLastServerID == id)
  }

  @Test("update server with a nil credential leaves the stored credential untouched")
  func updateServerWithNilCredentialLeavesCredential() {
    let manager = makeManagerWithLoadedService()
    guard let id = manager.servers.first?.id else {
      Issue.record("No server")
      return
    }
    let savesBefore = storage.saveCredentialCallCount
    let deletesBefore = storage.deleteCredentialCallCount

    manager.updateServer(id: id, label: "Renamed", url: "http://test.com", credential: nil)

    #expect(storage.credentials[id] == "old-password")
    #expect(storage.saveCredentialCallCount == savesBefore)
    #expect(storage.deleteCredentialCallCount == deletesBefore)
    #expect(manager.servers.first?.label == "Renamed")
    #expect(storage.servers.first?.label == "Renamed", "the label change persists")
  }

  @Test("update server with a replacement credential saves it")
  func updateServerWithReplacementCredentialSaves() {
    let manager = makeManagerWithLoadedService()
    guard let id = manager.servers.first?.id else {
      Issue.record("No server")
      return
    }

    manager.updateServer(id: id, label: "Test", url: "http://test.com", credential: "replacement")

    #expect(storage.credentials[id] == "replacement")
    #expect(storage.saveCredentialLastArgs?.credential == "replacement")
    #expect(storage.saveCredentialLastArgs?.serverID == id)
  }

  @Test("update server without a built service saves the credential and configuration")
  func updateServerWithoutServicePersists() {
    let config = ServerConfig(label: "Loose", url: "http://loose.local", version: .v5)
    let manager = makeManager()
    manager.servers = [config]

    manager.updateServer(id: config.id, label: "Loose Renamed", url: "http://loose.local", credential: "saved")

    #expect(storage.credentials[config.id] == "saved")
    #expect(storage.servers.first?.label == "Loose Renamed")
    #expect(storage.servers.first?.id == config.id)
  }

  @Test("addServer forwards the same storage instance to the factory")
  func addServerForwardsStorage() async throws {
    let manager = makeManager()

    try await manager.addServer(label: "Test", url: "http://test.com", credential: "secret")

    #expect(isSameStorageInstance(mockServiceFactory.buildServiceLastStorage, storage))
    #expect(mockServiceFactory.buildServiceLastCredential == "secret")
    #expect(storage.servers.count == 1)
  }

  @Test("delete server keeps other storage categories intact")
  func deleteServerKeepsTemporaryRecords() {
    let manager = makeManager()
    let server = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    manager.servers = [server]
    storage.credentials[server.id] = "secret"
    let record = TempUnblockRecord(
      domain: "kept.example",
      uuid: "kept-token",
      startDateUTC: Date(timeIntervalSince1970: 1_700_006_000),
      durationSeconds: 600
    )
    storage.temporaryUnblocks[server.id] = [record]

    manager.deleteServer(id: server.id)

    #expect(storage.servers.isEmpty)
    #expect(storage.credentials[server.id] == nil)
    #expect(
      storage.temporaryUnblocks[server.id]?.map(\.uuid) == ["kept-token"],
      "deleting a configuration must not delete temporary-unblock records"
    )
  }

  @Test("verifyCredential forwards the same storage instance")
  func verifyCredentialForwardsStorage() async throws {
    let manager = makeManagerWithLoadedService()
    guard let id = manager.servers.first?.id else {
      Issue.record("No server")
      return
    }
    let probe = MockPiholeService(id: id, url: "http://test.com", version: .v6)
    mockServiceFactory.buildServiceStub = probe

    _ = try await manager.verifyCredential(id: id, credential: "fresh-password")

    #expect(isSameStorageInstance(mockServiceFactory.buildServiceLastStorage, storage))
    #expect(mockServiceFactory.buildServiceLastCredential == "fresh-password")
  }

  @Test("update keeps configuration changes when the credential save fails")
  func updateCredentialSaveFailureRemainsBestEffort() {
    // Forward the configuration label like the real factory does, so a rebuild
    // does not blank it while this test checks best-effort persistence.
    mockServiceFactory.buildServiceHandler = { config in
      MockPiholeService(id: config.id, label: config.label, url: config.url, version: config.version)
    }
    let manager = makeManagerWithLoadedService()
    guard let id = manager.servers.first?.id else {
      Issue.record("No server")
      return
    }
    storage.saveCredentialStub = .failure(PiholeError.unknown("keychain unavailable"))

    manager.updateServer(
      id: id, label: "Renamed", icon: "moon", url: "http://test.com", credential: "replacement")

    #expect(storage.saveCredentialCallCount > 0)
    #expect(storage.servers.first?.label == "Renamed", "the configuration change still persists")
    #expect(storage.servers.first?.icon == "moon")
    #expect(
      storage.credentials[id] == "old-password",
      "a failed credential save keeps the previous credential")
    #expect(manager.servers.first?.label == "Renamed")
  }

  @Test("delete keeps the connection when credential cleanup fails")
  func deleteCredentialFailureKeepsConnectionForRetry() {
    let manager = makeManagerWithLoadedService()
    guard let id = manager.servers.first?.id else {
      Issue.record("No server")
      return
    }
    let record = TempUnblockRecord(
      domain: "survivor.example",
      uuid: "survivor-token",
      startDateUTC: Date(timeIntervalSince1970: 1_700_008_000),
      durationSeconds: 900
    )
    storage.temporaryUnblocks[id] = [record]
    storage.deleteCredentialStub = .failure(PiholeError.unknown("keychain unavailable"))

    #expect(manager.deleteServer(id: id) == false)

    #expect(storage.deleteCredentialCallCount > 0)
    #expect(manager.servers.map(\.id) == [id])
    #expect(storage.servers.map(\.id) == [id], "the UUID stays saved for cleanup retry")
    #expect(
      storage.credentials[id] == "old-password",
      "a failed credential delete keeps the stored credential")
    #expect(
      storage.temporaryUnblocks[id]?.map(\.uuid) == ["survivor-token"],
      "temporary-unblock records are untouched")
  }

  @Test("verifyCredential succeeds and logs out the probe service")
  func verifyCredentialSucceeds() async throws {
    let manager = makeManagerWithLoadedService()
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
    let manager = makeManagerWithLoadedService()
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
    let manager = makeManagerWithLoadedService()
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
    let manager = makeManagerWithLoadedService()
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
    let manager = makeManager()
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
    let manager = makeManager()
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
    let manager = makeManager()
    let server = ServerConfig(label: label, url: "http://192.168.1.20", version: .v6)
    manager.servers = [ServerConfig(label: "Other", url: "http://other.local", version: .v5), server]

    #expect(manager.displayLabel(for: server.id) == label)
  }

  @Test("Uses the hostname when the label is missing or blank", arguments: [nil, "", " \t\n"] as [String?])
  func missingLabel(label: String?) {
    let manager = makeManager()
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
    let manager = makeManager()
    let server = ServerConfig(url: url, version: .v6)
    manager.servers = [server]

    #expect(manager.displayLabel(for: server.id) == expected)
    #expect(manager.servers[0].url == url)
  }

  @Test("Returns nil for an unknown server")
  func unknownServer() {
    let manager = makeManager()
    manager.servers = [ServerConfig(label: "Kitchen", url: "http://192.168.1.20", version: .v6)]

    #expect(manager.displayLabel(for: UUID()) == nil)
  }

  // MARK: - On-demand reads

  @Test("Manager construction and reload do not log in; requested reads still work")
  func noWarmup() async throws {
    let service = MockPiholeService()
    storage.servers = [ServerConfig(id: service.id, url: service.url, version: service.version)]
    let factory = MockPiholeServiceFactory()
    factory.buildServiceStub = service
    let manager = PiholeServerManager(
      storage: storage, serviceFactory: factory,
      versionDetector: MockPiholeVersionDetector(), executionMode: .onDemand
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
    let service = MockPiholeService()
    storage.servers = [ServerConfig(id: service.id, url: service.url, version: service.version)]
    let factory = MockPiholeServiceFactory()
    factory.buildServiceStub = service
    let manager = PiholeServerManager(
      storage: storage, serviceFactory: factory,
      versionDetector: MockPiholeVersionDetector()
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
  private let storage = MockAppStorage()

  private func makeManager() -> PiholeServerManager {
    PiholeServerManager(
      storage: storage,
      serviceFactory: mockServiceFactory,
      versionDetector: MockPiholeVersionDetector()
    )
  }

  /// A manager with two configured servers, answered by `mockService1` and
  /// `mockService2`.
  private func makeManagerWithTwoServers() -> PiholeServerManager {
    storage.servers = [
      ServerConfig(id: mockService1.id, label: "Server A", url: "http://a.local", version: .v6),
      ServerConfig(id: mockService2.id, label: "Server B", url: "http://b.local", version: .v6)
    ]
    mockServiceFactory.buildServiceHandler = { config in
      config.id == mockService1.id ? mockService1 : mockService2
    }
    return makeManager()
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
      storage: storage, serviceFactory: MockPiholeServiceFactory(),
      versionDetector: MockPiholeVersionDetector()
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

@MainActor
@Suite("PiholeServerManager storage integration")
struct PiholeServerManagerStorageTests {
  private let keychain = MockKeychainManager()
  private let factory = MockPiholeServiceFactory()
  private let detector = MockPiholeVersionDetector()
  private let sharedData = TestDefaults.makeNamedSuite()
  private var sharedDataSuite: UserDefaults { sharedData.suite }
  private let appLocalSuite = TestDefaults.makeSuite()

  private func makeStorage() -> ConcreteAppStorage {
    ConcreteAppStorage(
      sharedDataSuite: sharedDataSuite,
      appLocalSuite: appLocalSuite,
      keychain: keychain
    )
  }

  private func makeManager(_ storage: any AppStorageProviding) -> PiholeServerManager {
    PiholeServerManager(storage: storage, serviceFactory: factory, versionDetector: detector)
  }

  /// Mirrors the real factory's habit of carrying the configuration label into
  /// the built service, so `syncConfigs` does not blank fields the test seeds.
  private func forwardConfigFields() {
    factory.buildServiceHandler = { config in
      MockPiholeService(id: config.id, label: config.label, url: config.url, version: config.version)
    }
  }

  @Test("reload rereads externally replaced configurations")
  func reloadRereadsExternalChanges() throws {
    forwardConfigFields()
    let first = ServerConfig(label: "First", icon: "star", url: "http://first.local", version: .v5)
    Defaults[.servers(suite: sharedDataSuite)] = [first]
    try keychain.saveCredential("first-secret", for: first.id)
    let storage = makeStorage()

    let manager = makeManager(storage)

    #expect(manager.servers.map(\.id) == [first.id])
    #expect(manager.servers.first?.icon == "star")
    let forwarded = try #require(factory.buildServiceLastConfig)
    #expect(forwarded.id == first.id)
    #expect(forwarded.label == "First")
    #expect(forwarded.icon == "star")
    #expect(forwarded.url == "http://first.local")
    #expect(forwarded.version == .v5)
    #expect(factory.buildServiceLastCredential == "first-secret")
    #expect(isSameStorageInstance(factory.buildServiceLastStorage, storage))

    // Another process replaces the stored configuration while the app runs.
    let second = ServerConfig(
      label: "Second", icon: "bolt", url: "http://second.local:8443", version: .v6)
    Defaults[.servers(suite: sharedDataSuite)] = [second]
    try keychain.saveCredential("second-secret", for: second.id)

    manager.reloadServers()

    #expect(manager.servers.map(\.id) == [second.id], "reload replaces the in-memory list")
    #expect(manager.servers.first?.icon == "bolt")
    #expect(manager.servers.first?.url == "http://second.local:8443")
    #expect(manager.servers.first?.version == .v6)
    let reloadedForwarded = try #require(factory.buildServiceLastConfig)
    #expect(reloadedForwarded.id == second.id)
    #expect(reloadedForwarded.label == "Second")
    #expect(reloadedForwarded.icon == "bolt")
    #expect(reloadedForwarded.url == "http://second.local:8443")
    #expect(reloadedForwarded.version == .v6)
    #expect(factory.buildServiceLastCredential == "second-secret")
    #expect(isSameStorageInstance(factory.buildServiceLastStorage, storage))
  }

  @Test("update and save preserve icons and order across reloads")
  func updatePreservesIconAndOrder() throws {
    forwardConfigFields()
    let first = ServerConfig(label: "A", icon: "star", url: "http://a.local", version: .v6)
    let second = ServerConfig(label: "B", icon: "bolt", url: "http://b.local", version: .v6)
    Defaults[.servers(suite: sharedDataSuite)] = [first, second]
    try keychain.saveCredential("a-secret", for: first.id)
    try keychain.saveCredential("b-secret", for: second.id)
    let storage = makeStorage()
    let manager = makeManager(storage)
    let buildsBefore = factory.buildServiceCallCount

    manager.updateServer(
      id: second.id, label: "B2", icon: "moon", url: "http://b2.local", credential: nil)

    #expect(
      factory.buildServiceCallCount == buildsBefore + 1,
      "a URL change reconnects through the same storage")
    #expect(factory.buildServiceLastCredential == "b-secret", "nil means no credential change")
    #expect(isSameStorageInstance(factory.buildServiceLastStorage, storage))

    #expect(manager.servers.map(\.id) == [first.id, second.id], "update keeps the stored order")
    #expect(manager.servers.first?.icon == "star", "the untouched server keeps its icon")
    #expect(manager.servers.last?.label == "B2")
    #expect(manager.servers.last?.icon == "moon")
    #expect(manager.servers.last?.url == "http://b2.local")

    let persisted = storage.loadServers()
    #expect(persisted.map(\.id) == [first.id, second.id])
    #expect(persisted.first?.icon == "star")
    #expect(persisted.last?.label == "B2")
    #expect(persisted.last?.icon == "moon")
    #expect(persisted.last?.url == "http://b2.local")

    // A relaunch over the same backing stores sees the saved order and fields.
    let relaunched = makeManager(makeStorage())
    #expect(relaunched.servers.map(\.id) == [first.id, second.id])
    #expect(relaunched.servers.first?.icon == "star")
    #expect(relaunched.servers.last?.label == "B2")
    #expect(relaunched.servers.last?.icon == "moon")
    #expect(relaunched.servers.last?.url == "http://b2.local")
  }
}
