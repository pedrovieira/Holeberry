import Defaults
import Foundation
import Testing

@testable import HoleberryCore

/// Reference error used to prove identity is preserved (not rebuilt) across the adapter.
private final class ConnectionStoreTestError: Error, CustomStringConvertible {
  let marker: String

  init(_ marker: String) {
    self.marker = marker
  }

  var description: String { "ConnectionStoreTestError(\(marker))" }
}

@MainActor
@Suite("ConnectionStore")
struct ConnectionStoreTests {
  /// Ordinary reads report no connections for a value that cannot be decoded.
  /// Startup owns the decision to preserve it and block editing.
  @Test func unreadableSavedListLoadsAsNoServers() {
    let suite = TestDefaults.makeSuite()
    let key = Defaults.Keys.servers(suite: suite)
    setRawDefaultsValue("not-an-array", for: key)
    let storage = makeTestConnectionStore(sharedData: suite)

    #expect(storage.loadServers().isEmpty)
  }

  /// Startup never hands out this adapter with editing enabled; it must not
  /// pretend that connections or credentials are available.
  @Test func unavailableStorageReportsNothingAndRefusesCredentials() {
    let storage = UnavailableConnectionStore()
    let id = UUID()

    #expect(storage.loadServers().isEmpty)
    #expect(throws: HoleberryError.storageUnavailable) {
      _ = try storage.readCredential(for: id)
    }
    #expect(throws: HoleberryError.storageUnavailable) {
      try storage.saveCredential("secret", for: id)
    }
    #expect(throws: HoleberryError.storageUnavailable) {
      try storage.deleteCredential(for: id)
    }
    #expect(throws: HoleberryError.storageUnavailable) {
      try storage.removeServer(id: id)
    }
  }

  private func makeConfig(
    id: UUID = UUID(),
    label: String? = nil,
    icon: String? = nil,
    url: String,
    version: ServerVersion,
    connectionRevision: UUID? = nil
  ) -> ServerConfig {
    ServerConfig(
      id: id, label: label, icon: icon, url: url, version: version,
      connectionRevision: connectionRevision)
  }

  private func expectConfigEquals(_ actual: ServerConfig, _ expected: ServerConfig) {
    #expect(actual.id == expected.id)
    #expect(actual.label == expected.label)
    #expect(actual.icon == expected.icon)
    #expect(actual.url == expected.url)
    #expect(actual.version == expected.version)
    #expect(actual.connectionRevision == expected.connectionRevision)
  }

  // MARK: - Compatibility

  @Test("loads existing arrays with all fields")
  func loadsExistingArraysWithAllFields() {
    let sharedDataSuite = TestDefaults.makeSuite()
    let first = makeConfig(
      label: "Alpha", icon: "star", url: "http://alpha.local/admin", version: .v5)
    let second = makeConfig(
      label: "Beta", icon: "bolt", url: "https://beta.local:8443", version: .v6,
      connectionRevision: UUID())
    Defaults[.servers(suite: sharedDataSuite)] = [first, second]

    let storage = makeTestConnectionStore(sharedData: sharedDataSuite)

    let servers = storage.loadServers()
    #expect(servers.count == 2)
    expectConfigEquals(servers[0], first)
    expectConfigEquals(servers[1], second)
  }

  @Test("save uses existing keys and persists empty arrays")
  func saveUsesExistingKeys() {
    let sharedDataSuite = TestDefaults.makeSuite()
    let storage = makeTestConnectionStore(sharedData: sharedDataSuite)
    let first = makeConfig(
      label: "First", icon: "star", url: "http://first.local", version: .v5,
      connectionRevision: UUID())
    let second = makeConfig(label: nil, icon: nil, url: "http://second.local", version: .v6)

    storage.saveServers([first, second])

    let savedConfigs: [ServerConfig] = Defaults[.servers(suite: sharedDataSuite)]
    #expect(savedConfigs.count == 2)
    expectConfigEquals(savedConfigs[0], first)
    expectConfigEquals(savedConfigs[1], second)

    // Replacing with an empty array persists an empty array under the same key.
    storage.saveServers([])
    #expect(Defaults[.servers(suite: sharedDataSuite)].isEmpty)
    #expect(sharedDataSuite.object(forKey: "servers") != nil)
  }

  @Test("loads read the current backing store")
  func loadsReadCurrentBackingStore() {
    let sharedDataSuite = TestDefaults.makeSuite()
    let storage = makeTestConnectionStore(sharedData: sharedDataSuite)
    #expect(storage.loadServers().isEmpty)

    let external = makeConfig(label: "External", icon: "globe", url: "http://external.local", version: .v6)
    Defaults[.servers(suite: sharedDataSuite)] = [external]

    let servers = storage.loadServers()
    #expect(servers.count == 1)
    expectConfigEquals(servers[0], external)
  }

  // MARK: - Separation

  @Test("saving servers leaves credentials alone")
  func savingServersLeavesCredentialsAlone() throws {
    let sharedDataSuite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let storage = makeTestConnectionStore(sharedData: sharedDataSuite, keychain: keychain)
    let serverID = UUID()
    storage.saveServers([makeConfig(label: "Kept", url: "http://kept.local", version: .v6)])
    try keychain.saveCredential("keep-me", for: serverID)

    storage.saveServers([makeConfig(label: "Again", url: "http://again.local", version: .v5)])

    #expect(keychain.storedCredentials[serverID.uuidString] == "keep-me")
  }

  // MARK: - Read isolation

  @Test("server loads read only the store suite", arguments: [true, false])
  func serverLoadsUseOnlyStoreSuite(intendedStorePopulated: Bool) {
    let sharedDataSuite = TestDefaults.makeSuite()
    let decoySuite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let intended = [
      makeConfig(label: "Intended", icon: "star", url: "http://intended.local", version: .v5),
      makeConfig(label: "Second", icon: "bolt", url: "https://second.local:8443", version: .v6)
    ]
    let decoy = [
      makeConfig(label: "Decoy", icon: "x", url: "http://decoy.local", version: .v6)
    ]
    Defaults[.servers(suite: decoySuite)] = decoy
    if intendedStorePopulated {
      Defaults[.servers(suite: sharedDataSuite)] = intended
    }
    let storage = makeTestConnectionStore(sharedData: sharedDataSuite, keychain: keychain)

    let loaded = storage.loadServers()

    #expect(
      keychain.readCredentialCallCount == 0,
      "a list read must not resolve credentials")
    #expect(keychain.saveCredentialCallCount == 0)
    #expect(keychain.deleteCredentialCallCount == 0)

    if intendedStorePopulated {
      #expect(loaded.count == intended.count)
      for (index, expected) in intended.enumerated() where index < loaded.count {
        expectConfigEquals(loaded[index], expected)
      }
    } else {
      #expect(
        loaded.isEmpty,
        "configurations must never fall back to another suite")
    }
  }

  // MARK: - Credentials

  @Test func clearingTheActivePasswordKeepsTheMigrationCopyUntilConnectionDeletion() throws {
    let sharedData = TestDefaults.makeNamedSuite()
    let legacy = MockKeychainManager()
    let shared = MockKeychainManager()
    let server = ServerConfig(url: "http://saved.local", version: .v6)
    let storage = makeTestConnectionStore(
      sharedData: sharedData.suite, keychain: shared, legacyKeychain: legacy)
    storage.saveServers([server])
    try legacy.saveCredential("legacy-secret", for: server.id)
    try shared.saveCredential("active-secret", for: server.id)

    try storage.deleteCredential(for: server.id)
    #expect(try legacy.readCredential(for: server.id) == "legacy-secret")
    #expect(try shared.readCredential(for: server.id) == nil)

    try storage.removeServer(id: server.id)
    #expect(try legacy.readCredential(for: server.id) == nil)
    #expect(storage.loadServers().isEmpty)
  }

  @Test func fallbackRemovalDeletesTheActiveCredentialOnce() throws {
    let sharedData = TestDefaults.makeNamedSuite()
    let legacy = MockKeychainManager()
    let server = ServerConfig(url: "http://fallback.local", version: .v6)
    // During fallback the legacy keychain is the active store, so no separate
    // cleanup copy exists and removal must delete exactly once.
    let storage = makeTestConnectionStore(sharedData: sharedData.suite, keychain: legacy)
    storage.saveServers([server])
    try legacy.saveCredential("legacy-secret", for: server.id)

    try storage.removeServer(id: server.id)

    #expect(legacy.deleteCredentialCallCount == 1)
    #expect(try legacy.readCredential(for: server.id) == nil)
    #expect(storage.loadServers().isEmpty)
  }

  @Test func legacyCleanupFailurePreservesActiveCredentialAndConnection() throws {
    let legacy = MockKeychainManager()
    let shared = MockKeychainManager()
    let server = ServerConfig(url: "http://saved.local", version: .v6)
    try legacy.saveCredential("original-secret", for: server.id)
    try shared.saveCredential("active-secret", for: server.id)
    let failure = ConnectionStoreTestError("legacy-locked")
    legacy.deleteErrorStub = failure
    let sharedData = TestDefaults.makeNamedSuite()
    let storage = makeTestConnectionStore(
      sharedData: sharedData.suite, keychain: shared, legacyKeychain: legacy)
    storage.saveServers([server])

    let error = #expect(throws: ConnectionStoreTestError.self) {
      try storage.removeServer(id: server.id)
    }

    #expect(error === failure)
    #expect(try storage.readCredential(for: server.id) == "active-secret")
    #expect(try legacy.readCredential(for: server.id) == "original-secret")
    #expect(storage.loadServers().map(\.id) == [server.id])

    legacy.deleteErrorStub = nil
    try storage.removeServer(id: server.id)

    #expect(try shared.readCredential(for: server.id) == nil)
    #expect(try legacy.readCredential(for: server.id) == nil)
    #expect(storage.loadServers().isEmpty)
  }

  @Test func activeCredentialDeletionFailurePreservesActiveCredentialAndConnection() throws {
    let legacy = MockKeychainManager()
    let active = MockKeychainManager()
    let server = ServerConfig(url: "http://saved.local", version: .v6)
    let failure = ConnectionStoreTestError("active-locked")
    try legacy.saveCredential("legacy-secret", for: server.id)
    try active.saveCredential("active-secret", for: server.id)
    active.deleteErrorStub = failure
    let sharedData = TestDefaults.makeNamedSuite()
    let storage = makeTestConnectionStore(
      sharedData: sharedData.suite, keychain: active, legacyKeychain: legacy)
    storage.saveServers([server])

    let error = #expect(throws: ConnectionStoreTestError.self) {
      try storage.removeServer(id: server.id)
    }

    #expect(error === failure)
    #expect(active.deleteCallCount == 1)
    #expect(legacy.deleteCallCount == 1)
    #expect(try active.readCredential(for: server.id) == "active-secret")
    #expect(try legacy.readCredential(for: server.id) == nil)
    #expect(storage.loadServers().map(\.id) == [server.id])

    active.deleteErrorStub = nil
    try storage.removeServer(id: server.id)

    #expect(try active.readCredential(for: server.id) == nil)
    #expect(storage.loadServers().isEmpty)
  }

  @Test("credential reads ignore decoy values in the store suite")
  func credentialReadsIgnoreDefaultsDecoys() throws {
    let sharedDataSuite = TestDefaults.makeSuite()
    let keychain = MockKeychainManager()
    let storage = makeTestConnectionStore(sharedData: sharedDataSuite, keychain: keychain)
    let serverID = UUID()

    // Synthetic test-only keys: production has no credential defaults key.
    sharedDataSuite.set("decoy-credential", forKey: "testOnlyDecoyCredential")
    sharedDataSuite.set(
      "decoy-credential-\(serverID.uuidString)",
      forKey: "testOnlyDecoyCredential-\(serverID.uuidString)")

    #expect(try storage.readCredential(for: serverID) == nil)
    #expect(keychain.readCredentialCallCount == 1)
    #expect(keychain.lastReadServerID == serverID)
    #expect(keychain.storedCredentials[serverID.uuidString] == nil)
  }

  @Test("credential roundtrip goes only to the injected keychain")
  func credentialRoundtrip() throws {
    let sharedData = TestDefaults.makeNamedSuite()
    let keychain = MockKeychainManager()
    let storage = makeTestConnectionStore(sharedData: sharedData.suite, keychain: keychain)
    let serverID = UUID()
    let secret = "super-secret-token"
    let sharedDataBaseline = NSDictionary(
      dictionary: sharedData.suite.persistentDomain(forName: sharedData.name) ?? [:])

    /// The suite may not gain, lose, or change a key during any credential operation.
    /// Reading the exact domain keeps this independent of the merged search list.
    func expectNoSuiteWrites(_ moment: String) {
      let sharedDataNow = NSDictionary(
        dictionary: sharedData.suite.persistentDomain(forName: sharedData.name) ?? [:])
      #expect(sharedDataNow.isEqual(sharedDataBaseline), "shared-data suite changed \(moment)")
    }

    #expect(try storage.readCredential(for: serverID) == nil)
    #expect(keychain.readCredentialCallCount == 1)
    #expect(keychain.lastReadServerID == serverID)
    expectNoSuiteWrites("during an absent read")

    try storage.saveCredential(secret, for: serverID)
    #expect(keychain.saveCredentialCallCount == 1)
    #expect(keychain.lastSavedCredential?.credential == secret)
    #expect(keychain.lastSavedCredential?.serverID == serverID)
    #expect(keychain.storedCredentials[serverID.uuidString] == secret)
    expectNoSuiteWrites("during save")

    #expect(try storage.readCredential(for: serverID) == secret)
    expectNoSuiteWrites("during a successful read")

    try storage.deleteCredential(for: serverID)
    #expect(keychain.deleteCredentialCallCount == 1)
    #expect(keychain.lastDeletedServerID == serverID)
    #expect(try storage.readCredential(for: serverID) == nil)
    expectNoSuiteWrites("during delete")
  }

  @Test("credential errors propagate with identity preserved")
  func credentialErrorsPropagate() {
    let keychain = MockKeychainManager()
    let original = ConnectionStoreTestError("keychain-failure")
    keychain.errorStub = original
    let sharedData = TestDefaults.makeNamedSuite()
    let storage = makeTestConnectionStore(sharedData: sharedData.suite, keychain: keychain)
    let serverID = UUID()

    let readError = #expect(throws: ConnectionStoreTestError.self) {
      _ = try storage.readCredential(for: serverID)
    }
    #expect(readError === original)

    let saveError = #expect(throws: ConnectionStoreTestError.self) {
      try storage.saveCredential("value", for: serverID)
    }
    #expect(saveError === original)

    let deleteError = #expect(throws: ConnectionStoreTestError.self) {
      try storage.deleteCredential(for: serverID)
    }
    #expect(deleteError === original)
  }
}
