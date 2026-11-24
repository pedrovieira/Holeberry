import Defaults
import Foundation
import Testing

@testable import HoleberryCore

private struct PersistentChangeTestError: Error {}

@Suite("PiholeServerManager persistent changes")
@MainActor
struct PiholeServerManagerPersistentChangeTests {
  @Test func unreadablePasswordsDoNotBlockCredentialDeletion() throws {
    let suite = TestDefaults.makeSuite()
    let legacy = MockKeychainManager()
    let shared = MockKeychainManager()
    let server = ServerConfig(id: UUID(), url: "http://saved.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    try legacy.saveCredential("original-secret", for: server.id)
    try shared.saveCredential("shared-secret", for: server.id)
    let manager = PiholeServerManager(
      storage: ConcreteAppStorage(
        sharedDataSuite: suite,
        appLocalSuite: TestDefaults.makeSuite(),
        keychain: shared,
        legacyKeychain: legacy
      ),
      serviceFactory: MockPiholeServiceFactory(),
      versionDetector: MockPiholeVersionDetector(),
      urlSessionFactory: MockURLSessionFactory()
    )
    legacy.readErrorStub = PersistentChangeTestError()
    shared.readErrorStub = PersistentChangeTestError()

    #expect(manager.deleteServer(id: server.id))

    #expect(manager.servers.isEmpty)
    #expect(Defaults[.servers(suite: suite)].isEmpty)
    #expect(legacy.storedCredentials[server.id.uuidString] == nil)
    #expect(shared.storedCredentials[server.id.uuidString] == nil)
  }

  @Test(arguments: ["legacy", "shared"])
  func failedCredentialCleanupKeepsConnectionForRetry(failingStore: String) throws {
    let suite = TestDefaults.makeSuite()
    let legacy = MockKeychainManager()
    let shared = MockKeychainManager()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    try legacy.saveCredential("original-secret", for: server.id)
    try shared.saveCredential("shared-secret", for: server.id)
    let storage = ConcreteAppStorage(
      sharedDataSuite: suite,
      appLocalSuite: TestDefaults.makeSuite(),
      keychain: shared,
      legacyKeychain: legacy
    )
    var changes = 0
    let manager = PiholeServerManager(
      storage: storage,
      serviceFactory: MockPiholeServiceFactory(),
      versionDetector: MockPiholeVersionDetector(),
      urlSessionFactory: MockURLSessionFactory(),
      persistentChangeHandler: { changes += 1 }
    )
    let denied = failingStore == "legacy" ? legacy : shared
    denied.errorStub = PersistentChangeTestError()

    #expect(manager.deleteServer(id: server.id) == false)

    #expect(manager.servers.map(\.id) == [server.id])
    #expect(storage.loadServers().map(\.id) == [server.id])
    #expect(changes == 0)

    denied.errorStub = nil
    #expect(manager.deleteServer(id: server.id))

    #expect(manager.servers.isEmpty)
    #expect(storage.loadServers().isEmpty)
    #expect(try legacy.readCredential(for: server.id) == nil)
    #expect(try shared.readCredential(for: server.id) == nil)
    #expect(changes == 1)
  }

  @Test func deletingMigratedServerRemovesBothCredentialCopies() throws {
    let suite = TestDefaults.makeSuite()
    let legacyKeychain = MockKeychainManager()
    let sharedKeychain = MockKeychainManager()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    try legacyKeychain.saveCredential("original-secret", for: server.id)
    try sharedKeychain.saveCredential("shared-secret", for: server.id)
    let storage = ConcreteAppStorage(
      sharedDataSuite: suite,
      appLocalSuite: TestDefaults.makeSuite(),
      keychain: sharedKeychain,
      legacyKeychain: legacyKeychain
    )
    let manager = PiholeServerManager(
      storage: storage,
      serviceFactory: MockPiholeServiceFactory(),
      versionDetector: MockPiholeVersionDetector(),
      urlSessionFactory: MockURLSessionFactory()
    )

    manager.deleteServer(id: server.id)

    #expect(storage.loadServers().isEmpty)
    #expect(try sharedKeychain.readCredential(for: server.id) == nil)
    #expect(try legacyKeychain.readCredential(for: server.id) == nil)
  }

  @Test func credentialOnlyUpdateFiresAfterCredentialSave() throws {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let server = ServerConfig(id: UUID(), label: "Home", url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    try keychain.saveCredential("old-secret", for: server.id)
    var snapshots: [PersistentChangeSnapshot] = []
    let manager = makeManager(suite: suite, keychain: keychain) {
      snapshots.append(
        PersistentChangeSnapshot(
          credential: try? keychain.readCredential(for: server.id),
          servers: Defaults[.servers(suite: suite)]
        )
      )
    }

    manager.updateServer(
      id: server.id,
      label: server.label,
      icon: server.icon,
      url: server.url,
      credential: "new-secret"
    )

    #expect(snapshots.count == 1)
    #expect(snapshots.first?.credential == "new-secret")
    #expect(snapshots.first?.servers.first?.id == server.id)
  }

  @Test func configEditFiresAfterConfigSave() throws {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let server = ServerConfig(id: UUID(), label: "Old", url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    var snapshots: [PersistentChangeSnapshot] = []
    let manager = makeManager(suite: suite, keychain: keychain) {
      snapshots.append(
        PersistentChangeSnapshot(
          credential: try? keychain.readCredential(for: server.id),
          servers: Defaults[.servers(suite: suite)]
        )
      )
    }

    manager.updateServer(
      id: server.id,
      label: "New",
      icon: "house",
      url: server.url,
      credential: nil
    )

    #expect(snapshots.count == 1)
    #expect(snapshots.first?.servers.first?.label == "New")
    #expect(snapshots.first?.servers.first?.icon == "house")
  }

  @Test func addFiresAfterCredentialSave() async throws {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    var snapshots: [PersistentChangeSnapshot] = []
    let manager = makeManager(suite: suite, keychain: keychain) {
      let servers = Defaults[.servers(suite: suite)]
      snapshots.append(
        PersistentChangeSnapshot(
          credential: servers.first.flatMap { try? keychain.readCredential(for: $0.id) },
          servers: servers
        )
      )
    }

    try await manager.addServer(label: "Home", url: "http://pihole.local", credential: "secret")

    #expect(snapshots.count == 1)
    #expect(snapshots.first?.credential == "secret")
    #expect(snapshots.first?.servers.count == 1)
  }

  @Test func deleteFiresAfterCredentialDelete() throws {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let server = ServerConfig(id: UUID(), label: "Home", url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    try keychain.saveCredential("secret", for: server.id)
    var snapshots: [PersistentChangeSnapshot] = []
    let manager = makeManager(suite: suite, keychain: keychain) {
      snapshots.append(
        PersistentChangeSnapshot(
          credential: try? keychain.readCredential(for: server.id),
          servers: Defaults[.servers(suite: suite)]
        )
      )
    }

    manager.deleteServer(id: server.id)

    #expect(snapshots.count == 1)
    #expect(snapshots.first?.credential == nil)
    #expect(snapshots.first?.servers.isEmpty == true)
  }

  @Test func failedAddDoesNotFire() async {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    keychain.saveErrorStub = PersistentChangeTestError()
    var fireCount = 0
    let manager = makeManager(suite: suite, keychain: keychain) {
      fireCount += 1
    }

    await #expect(throws: PersistentChangeTestError.self) {
      try await manager.addServer(label: "Home", url: "http://pihole.local", credential: "secret")
    }

    #expect(fireCount == 0)
    #expect(manager.servers.isEmpty)
  }

  @Test func passwordlessAddWhileChangesDisabledFailsBeforeVersionDetection() async {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let detector = MockPiholeVersionDetector()
    var fireCount = 0
    let manager = makeManager(
      suite: suite,
      keychain: keychain,
      versionDetector: detector,
      allowsServerChanges: false
    ) {
      fireCount += 1
    }

    await #expect(throws: HoleberryError.storageUnavailable) {
      try await manager.addServer(label: "Home", url: "http://pihole.local", credential: "")
    }

    #expect(detector.detectCallCount == 0)
    #expect(manager.servers.isEmpty)
    #expect(Defaults[.servers(suite: suite)].isEmpty)
    #expect(fireCount == 0)
  }

  @Test func editWhileChangesDisabledLeavesConfigurationUnchanged() throws {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let server = ServerConfig(id: UUID(), label: "Old", url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    try keychain.saveCredential("old-secret", for: server.id)
    var fireCount = 0
    let manager = makeManager(suite: suite, keychain: keychain, allowsServerChanges: false) {
      fireCount += 1
    }

    manager.updateServer(
      id: server.id,
      label: "New",
      icon: "house",
      url: "http://changed.local",
      credential: "new-secret"
    )

    #expect(manager.servers.map(\.id) == [server.id])
    #expect(manager.servers.first?.url == "http://pihole.local")
    #expect(Defaults[.servers(suite: suite)].first?.label == "Old")
    #expect(Defaults[.servers(suite: suite)].first?.icon == nil)
    #expect(try keychain.readCredential(for: server.id) == "old-secret")
    #expect(fireCount == 0)
  }

  @Test func deleteWhileChangesDisabledLeavesServerAndCredential() throws {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let server = ServerConfig(id: UUID(), label: "Home", url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    try keychain.saveCredential("secret", for: server.id)
    var fireCount = 0
    let manager = makeManager(suite: suite, keychain: keychain, allowsServerChanges: false) {
      fireCount += 1
    }

    manager.deleteServer(id: server.id)

    #expect(manager.servers.map(\.id) == [server.id])
    #expect(Defaults[.servers(suite: suite)].map(\.id) == [server.id])
    #expect(try keychain.readCredential(for: server.id) == "secret")
    #expect(fireCount == 0)
  }

  @Test func credentialOnlyEditAdvancesTheConnectionRevisionBeforeTheCallback() throws {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let server = ServerConfig(id: UUID(), label: "Home", url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    try keychain.saveCredential("old-secret", for: server.id)
    let oldConfigs = Defaults[.servers(suite: suite)]
    let storage = makeTestStorage(
      appLocalSuite: TestDefaults.makeSuite(), sharedData: suite, keychain: keychain)
    var snapshots: [PersistentChangeSnapshot] = []
    let manager = PiholeServerManager(
      storage: storage,
      serviceFactory: MockPiholeServiceFactory(),
      versionDetector: MockPiholeVersionDetector(),
      urlSessionFactory: MockURLSessionFactory(),
      persistentChangeHandler: {
        snapshots.append(
          PersistentChangeSnapshot(
            credential: try? keychain.readCredential(for: server.id),
            servers: Defaults[.servers(suite: suite)]
          )
        )
      }
    )

    manager.updateServer(
      id: server.id,
      label: server.label,
      icon: server.icon,
      url: server.url,
      credential: "new-secret"
    )

    let persisted = try #require(snapshots.first?.servers.first)
    let previous = try #require(oldConfigs.first)
    #expect(snapshots.first?.credential == "new-secret")
    #expect(persisted.connectionRevision != nil)
    #expect(persisted.connectionRevision != previous.connectionRevision)
    #expect(!previous.hasSameConnection(as: persisted))
    #expect(manager.servers.first?.connectionRevision == persisted.connectionRevision)
  }

  @Test func credentialOnlyEditRejectsABatchThatFailedWithTheOldCredential() throws {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let server = ServerConfig(id: UUID(), label: "Home", url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    try keychain.saveCredential("rejected-secret", for: server.id)
    let storage = makeTestStorage(
      appLocalSuite: TestDefaults.makeSuite(), sharedData: suite, keychain: keychain)
    let manager = PiholeServerManager(
      storage: storage,
      serviceFactory: MockPiholeServiceFactory(),
      versionDetector: MockPiholeVersionDetector(),
      urlSessionFactory: MockURLSessionFactory()
    )
    // Simulate an authentication failure from before the credential edit.
    let inFlightConfigs = storage.loadServers()
    let staleResults: [UUID: Result<QuerySummary, PiholeError>] = [
      server.id: .failure(.invalidCredentials)
    ]
    let checkedAt = Date(timeIntervalSince1970: 1_000)
    let staleBatch = QueryStatisticsSnapshot(
      scope: .all,
      setupRequired: false,
      observations: ServerQueryObservation.make(
        servers: inFlightConfigs,
        results: staleResults,
        checkedAt: checkedAt
      )
    )
    #expect(staleBatch.availability(at: checkedAt) == .noneAvailable)

    manager.updateServer(
      id: server.id,
      label: server.label,
      icon: server.icon,
      url: server.url,
      credential: "accepted-secret"
    )

    let current = storage.loadServers()
    // Match the widget's post-fetch connection check.
    let acceptsStaleBatch = current.elementsEqual(inFlightConfigs, by: { $0.hasSameConnection(as: $1) })
    #expect(!acceptsStaleBatch)
    #expect(try keychain.readCredential(for: server.id) == "accepted-secret")
  }

  @Test func clearingTheCredentialAdvancesTheConnectionRevision() throws {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    try keychain.saveCredential("old-secret", for: server.id)
    let storage = makeTestStorage(
      appLocalSuite: TestDefaults.makeSuite(), sharedData: suite, keychain: keychain)
    let manager = PiholeServerManager(
      storage: storage,
      serviceFactory: MockPiholeServiceFactory(),
      versionDetector: MockPiholeVersionDetector(),
      urlSessionFactory: MockURLSessionFactory()
    )

    manager.updateServer(
      id: server.id,
      label: server.label,
      icon: server.icon,
      url: server.url,
      credential: ""
    )

    let persisted = try #require(storage.loadServers().first)
    #expect(try keychain.readCredential(for: server.id) == nil)
    #expect(persisted.connectionRevision != nil)
    #expect(!server.hasSameConnection(as: persisted))
  }

  @Test func metadataOnlyEditKeepsTheConnectionRevision() throws {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let revision = UUID()
    let server = ServerConfig(
      id: UUID(), label: "Old", url: "http://pihole.local", version: .v6, connectionRevision: revision)
    Defaults[.servers(suite: suite)] = [server]
    try keychain.saveCredential("secret", for: server.id)
    let storage = makeTestStorage(
      appLocalSuite: TestDefaults.makeSuite(), sharedData: suite, keychain: keychain)
    let manager = PiholeServerManager(
      storage: storage,
      serviceFactory: MockPiholeServiceFactory(),
      versionDetector: MockPiholeVersionDetector(),
      urlSessionFactory: MockURLSessionFactory()
    )

    manager.updateServer(
      id: server.id,
      label: "New",
      icon: "house",
      url: server.url,
      credential: nil
    )

    let persisted = try #require(storage.loadServers().first)
    #expect(persisted.label == "New")
    #expect(persisted.connectionRevision == revision)
    #expect(server.hasSameConnection(as: persisted))
  }

  @Test func failedCredentialSaveKeepsTheConnectionRevisionAndStoredCredential() throws {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let revision = UUID()
    let server = ServerConfig(
      id: UUID(), label: "Home", url: "http://pihole.local", version: .v6, connectionRevision: revision)
    Defaults[.servers(suite: suite)] = [server]
    try keychain.saveCredential("old-secret", for: server.id)
    keychain.saveErrorStub = PersistentChangeTestError()
    let storage = makeTestStorage(
      appLocalSuite: TestDefaults.makeSuite(), sharedData: suite, keychain: keychain)
    let manager = PiholeServerManager(
      storage: storage,
      serviceFactory: MockPiholeServiceFactory(),
      versionDetector: MockPiholeVersionDetector(),
      urlSessionFactory: MockURLSessionFactory()
    )

    manager.updateServer(
      id: server.id,
      label: server.label,
      icon: server.icon,
      url: server.url,
      credential: "new-secret"
    )

    let persisted = try #require(storage.loadServers().first)
    #expect(persisted.connectionRevision == revision)
    #expect(manager.servers.first?.connectionRevision == revision)
    #expect(try keychain.readCredential(for: server.id) == "old-secret")
  }

  @Test func clearingCredentialAdvancesRevisionWhenTheStoredReadFails() throws {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    try keychain.saveCredential("old-secret", for: server.id)
    let storage = makeTestStorage(
      appLocalSuite: TestDefaults.makeSuite(), sharedData: suite, keychain: keychain)
    let manager = PiholeServerManager(
      storage: storage,
      serviceFactory: MockPiholeServiceFactory(),
      versionDetector: MockPiholeVersionDetector(),
      urlSessionFactory: MockURLSessionFactory()
    )
    let inFlightConfigs = storage.loadServers()
    // Deletion can succeed even when reading the credential fails.
    keychain.readErrorStub = PersistentChangeTestError()

    manager.updateServer(
      id: server.id,
      label: server.label,
      icon: server.icon,
      url: server.url,
      credential: ""
    )

    let persisted = try #require(storage.loadServers().first)
    #expect(keychain.storedCredentials[server.id.uuidString] == nil)
    #expect(persisted.connectionRevision != nil)
    #expect(!inFlightConfigs[0].hasSameConnection(as: persisted))
    let acceptsStaleBatch = [persisted].elementsEqual(inFlightConfigs, by: { $0.hasSameConnection(as: $1) })
    #expect(!acceptsStaleBatch)
  }

  @Test func metadataOnlyEditDoesNotReadTheCredential() throws {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let server = ServerConfig(id: UUID(), label: "Old", url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    try keychain.saveCredential("old-secret", for: server.id)
    let storage = makeTestStorage(
      appLocalSuite: TestDefaults.makeSuite(), sharedData: suite, keychain: keychain)
    let manager = PiholeServerManager(
      storage: storage,
      serviceFactory: MockPiholeServiceFactory(),
      versionDetector: MockPiholeVersionDetector(),
      urlSessionFactory: MockURLSessionFactory()
    )
    let readsAfterInitialization = keychain.readCredentialCallCount

    manager.updateServer(
      id: server.id,
      label: "New",
      icon: "house",
      url: server.url,
      credential: nil
    )

    #expect(keychain.readCredentialCallCount == readsAfterInitialization)
    #expect(storage.loadServers().first?.label == "New")
    #expect(keychain.storedCredentials[server.id.uuidString] == "old-secret")
  }

  @Test func byteDistinctCredentialReplacementAdvancesRevisionAndRebuildsWithExactBytes() throws {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let factory = MockPiholeServiceFactory()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    // Canonically equal strings with different UTF-8 bytes, as a keychain can hold.
    let precomposed = "caf\u{00E9}"
    let decomposed = "cafe\u{0301}"
    #expect(precomposed == decomposed)
    #expect(!Array(precomposed.utf8).elementsEqual(decomposed.utf8))
    try keychain.saveCredential(precomposed, for: server.id)
    let storage = makeTestStorage(
      appLocalSuite: TestDefaults.makeSuite(), sharedData: suite, keychain: keychain)
    let manager = PiholeServerManager(
      storage: storage,
      serviceFactory: factory,
      versionDetector: MockPiholeVersionDetector(),
      urlSessionFactory: MockURLSessionFactory()
    )
    let inFlightConfigs = storage.loadServers()

    manager.updateServer(
      id: server.id,
      label: server.label,
      icon: server.icon,
      url: server.url,
      credential: decomposed
    )

    let persisted = try #require(storage.loadServers().first)
    let rebuiltCredential = try #require(factory.buildServiceLastCredential)
    let storedCredential = try #require(keychain.storedCredentials[server.id.uuidString])
    #expect(Array(rebuiltCredential.utf8).elementsEqual(decomposed.utf8))
    #expect(Array(storedCredential.utf8).elementsEqual(decomposed.utf8))
    #expect(persisted.connectionRevision != nil)
    #expect(!inFlightConfigs[0].hasSameConnection(as: persisted))
  }

  @Test func sameCredentialSaveStillAdvancesTheConnectionRevision() throws {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let server = ServerConfig(id: UUID(), url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    try keychain.saveCredential("same-secret", for: server.id)
    let storage = makeTestStorage(
      appLocalSuite: TestDefaults.makeSuite(), sharedData: suite, keychain: keychain)
    let manager = PiholeServerManager(
      storage: storage,
      serviceFactory: MockPiholeServiceFactory(),
      versionDetector: MockPiholeVersionDetector(),
      urlSessionFactory: MockURLSessionFactory()
    )
    let previousRevision = storage.loadServers().first?.connectionRevision

    manager.updateServer(
      id: server.id,
      label: server.label,
      icon: server.icon,
      url: server.url,
      credential: "same-secret"
    )

    let persisted = try #require(storage.loadServers().first)
    #expect(persisted.connectionRevision != previousRevision)
    #expect(persisted.connectionRevision != nil)
    #expect(keychain.storedCredentials[server.id.uuidString] == "same-secret")
  }

  @Test func failedCredentialDeleteKeepsTheConnectionRevision() throws {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let revision = UUID()
    let server = ServerConfig(
      id: UUID(), url: "http://pihole.local", version: .v6, connectionRevision: revision)
    Defaults[.servers(suite: suite)] = [server]
    try keychain.saveCredential("old-secret", for: server.id)
    keychain.deleteErrorStub = PersistentChangeTestError()
    let storage = makeTestStorage(
      appLocalSuite: TestDefaults.makeSuite(), sharedData: suite, keychain: keychain)
    let manager = PiholeServerManager(
      storage: storage,
      serviceFactory: MockPiholeServiceFactory(),
      versionDetector: MockPiholeVersionDetector(),
      urlSessionFactory: MockURLSessionFactory()
    )

    manager.updateServer(
      id: server.id,
      label: server.label,
      icon: server.icon,
      url: server.url,
      credential: ""
    )

    let persisted = try #require(storage.loadServers().first)
    #expect(persisted.connectionRevision == revision)
    #expect(manager.servers.first?.connectionRevision == revision)
    #expect(keychain.storedCredentials[server.id.uuidString] == "old-secret")
  }

  @Test func reloadAndVersionSyncPreserveTheConnectionRevision() throws {
    let suite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let server = ServerConfig(id: UUID(), label: "Home", url: "http://pihole.local", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    try keychain.saveCredential("old-secret", for: server.id)
    let storage = makeTestStorage(
      appLocalSuite: TestDefaults.makeSuite(), sharedData: suite, keychain: keychain)
    let manager = PiholeServerManager(
      storage: storage,
      serviceFactory: MockPiholeServiceFactory(),
      versionDetector: MockPiholeVersionDetector(),
      urlSessionFactory: MockURLSessionFactory()
    )
    manager.updateServer(
      id: server.id,
      label: server.label,
      icon: server.icon,
      url: server.url,
      credential: "new-secret"
    )
    let revision = try #require(storage.loadServers().first?.connectionRevision)

    manager.reloadServers()
    #expect(manager.servers.first?.connectionRevision == revision)

    manager.updateServerVersion(id: server.id, version: .v5)
    let persisted = try #require(storage.loadServers().first)
    #expect(persisted.connectionRevision == revision)
    #expect(persisted.version == .v5)
  }

  private struct PersistentChangeSnapshot {
    let credential: String?
    let servers: [ServerConfig]
  }

  private func makeManager(
    suite: UserDefaults,
    keychain: MockKeychainManager,
    versionDetector: MockPiholeVersionDetector = MockPiholeVersionDetector(),
    allowsServerChanges: Bool = true,
    persistentChangeHandler: @escaping () -> Void = {}
  ) -> PiholeServerManager {
    PiholeServerManager(
      storage: makeTestStorage(
        appLocalSuite: TestDefaults.makeSuite(), sharedData: suite, keychain: keychain),
      serviceFactory: MockPiholeServiceFactory(),
      versionDetector: versionDetector,
      urlSessionFactory: MockURLSessionFactory(),
      allowsServerChanges: allowsServerChanges,
      persistentChangeHandler: persistentChangeHandler
    )
  }
}
