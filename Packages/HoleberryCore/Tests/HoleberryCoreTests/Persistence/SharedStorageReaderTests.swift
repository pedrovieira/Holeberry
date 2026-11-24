import Defaults
import Foundation
import Testing

@testable import HoleberryCore

private struct SharedReaderTestError: Error, Equatable {}

/// A persistent domain that changes between snapshots. A read that captures the
/// dictionary more than once can pair a marker from one state with a list from
/// another.
private final class SequencedDomainDefaults: UserDefaults {
  var domains: [[String: Any]] = []
  private(set) var persistentDomainCallCount = 0

  override func persistentDomain(forName domainName: String) -> [String: Any]? {
    persistentDomainCallCount += 1
    return domains[min(persistentDomainCallCount - 1, domains.count - 1)]
  }
}

@MainActor
@Suite("SharedStorageReader")
struct SharedStorageReaderTests {
  /// One App Group suite, one shared keychain stub, and a reader over both.
  @MainActor
  private final class Harness {
    let suite: UserDefaults
    let suiteName: String
    let keychain = MockKeychainManager()
    let sharedStorage: StubSharedStorage
    let reader: ConcreteSharedStorageReader

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

    var serversKey: Defaults.Key<[ServerConfig]> {
      Defaults.Keys.servers(suite: suite)
    }

    var markerKey: Defaults.Key<Int> {
      Defaults.Keys.sharedStorageMigrationVersion(suite: suite)
    }

    /// Publishes a completed copy. `servers: nil` leaves the list absent.
    func publish(_ servers: [ServerConfig]?) {
      Defaults[markerKey] = SharedStorageValidation.currentVersion
      if let servers {
        Defaults[serversKey] = servers
      }
    }
  }

  private func makeServer(label: String = "Home", credential: String? = "secret") -> (ServerConfig, Harness) {
    let harness = Harness()
    let server = ServerConfig(label: label, url: "http://\(label.lowercased()).local", version: .v6)
    harness.publish([server])
    if let credential {
      harness.keychain.storedCredentials[server.id.uuidString] = credential
    }
    return (server, harness)
  }

  // MARK: - Opening

  @Test func serverListOpenResolvesNoCredentials() throws {
    let (server, harness) = makeServer()
    let other = ServerConfig(label: "Other", url: "http://other.local", version: .v5)
    harness.publish([server, other])

    let reader = try harness.reader.openServerReader()

    #expect(reader.loadServers().map(\.id) == [server.id, other.id])
    #expect(harness.sharedStorage.keychainCallCount == 0, "a list read must not resolve a keychain")
    #expect(harness.keychain.readCredentialCallCount == 0)
    #expect(harness.keychain.saveCredentialCallCount == 0)
    #expect(harness.keychain.deleteCredentialCallCount == 0)
  }

  @Test func connectionsOpenResolvesTheSharedCredentialStoreOnce() throws {
    let (server, harness) = makeServer(credential: "shared-secret")

    let connections = try harness.reader.openConnectionReader()

    #expect(connections.loadServers().map(\.id) == [server.id])
    #expect(harness.sharedStorage.keychainCallCount == 1)
    #expect(try connections.readCredential(for: server.id) == "shared-secret")
    #expect(try connections.readCredential(for: UUID()) == nil)
    #expect(harness.keychain.saveCredentialCallCount == 0)
    #expect(harness.keychain.deleteCredentialCallCount == 0)
  }

  @Test func explicitlyEmptyListIsReadable() throws {
    let harness = Harness()
    harness.publish([])

    #expect(try harness.reader.openServerReader().loadServers().isEmpty)
    #expect(try harness.reader.openConnectionReader().loadServers().isEmpty)
  }

  @Test func unpublishedCopyIsNotReadable() {
    let harness = Harness()

    #expect(throws: SharedStorageAccessError.copyNotPublished) {
      try harness.reader.openServerReader()
    }
    #expect(throws: SharedStorageAccessError.copyNotPublished) {
      try harness.reader.openConnectionReader()
    }

    // An explicit zero marker is the same unpublished state.
    Defaults[harness.markerKey] = 0
    #expect(throws: SharedStorageAccessError.copyNotPublished) {
      try harness.reader.openServerReader()
    }
  }


  // MARK: - Snapshot atomicity

  @Test(arguments: [false, true])
  func sharedOpenReadsOnePersistentDomainSnapshot(withdrawsCompletion: Bool) throws {
    let first = ServerConfig(label: "First", url: "http://first.local", version: .v6)
    let replacement = ServerConfig(label: "Replacement", url: "http://replacement.local", version: .v5)
    let ready = try rawDomain(servers: [first], marker: SharedStorageValidation.currentVersion)
    // The second snapshot is the replacement: a non-atomic read would pair the
    // first snapshot's ready marker with this list. Withdrawal makes it the
    // unpublished case.
    let replacementMarker = withdrawsCompletion ? 0 : SharedStorageValidation.currentVersion
    let next = try rawDomain(servers: [replacement], marker: replacementMarker)

    let serverReads = try sequencedReadCount(ready: ready, next: next) { reader in
      let servers = try reader.openServerReader().loadServers()
      #expect(servers.map(\.id) == [first.id], "one open must not mix two domain snapshots")
    }
    #expect(serverReads == 1)

    let connectionReads = try sequencedReadCount(ready: ready, next: next) { reader in
      let connections = try reader.openConnectionReader()
      #expect(connections.loadServers().map(\.id) == [first.id])
    }
    #expect(connectionReads == 1)
  }

  /// Runs one open against a fresh changing-domain fixture and returns how many
  /// persistent-domain snapshots it captured.
  private func sequencedReadCount(
    ready: [String: Any],
    next: [String: Any],
    _ open: (ConcreteSharedStorageReader) throws -> Void
  ) throws -> Int {
    let defaults = try #require(
      SequencedDomainDefaults(suiteName: "com.holeberry.tests.sequenced.\(UUID().uuidString)")
    )
    defaults.domains = [ready, next]
    let storage = StubSharedStorage(
      location: SharedStorageLocation(suite: defaults, suiteName: "sequenced"),
      keychain: MockKeychainManager()
    )
    try open(ConcreteSharedStorageReader(sharedStorage: storage))
    return defaults.persistentDomainCallCount
  }

  private func rawDomain(servers: [ServerConfig], marker: Int) throws -> [String: Any] {
    let named = TestDefaults.makeNamedSuite()
    Defaults[.servers(suite: named.suite)] = servers
    Defaults[.sharedStorageMigrationVersion(suite: named.suite)] = marker
    return try #require(named.suite.persistentDomain(forName: named.name))
  }

  // MARK: - Per-open validation

  @Test func eachOpenRevalidatesTheCurrentList() throws {
    let (first, harness) = makeServer(label: "First")
    let firstSnapshot = try harness.reader.openServerReader()
    #expect(firstSnapshot.loadServers().map(\.id) == [first.id])

    let second = ServerConfig(label: "Second", url: "http://second.local", version: .v5)
    harness.publish([second])

    #expect(try harness.reader.openServerReader().loadServers().map(\.id) == [second.id])
    #expect(
      firstSnapshot.loadServers().map(\.id) == [first.id],
      "an open snapshot does not change when the store changes")
  }

  @Test func resetCompletionMarkerBlocksTheNextOpen() throws {
    let (_, harness) = makeServer()
    #expect(try harness.reader.openServerReader().loadServers().count == 1)

    Defaults[harness.markerKey] = 0

    #expect(throws: SharedStorageAccessError.copyNotPublished) {
      try harness.reader.openServerReader()
    }
    #expect(throws: SharedStorageAccessError.copyNotPublished) {
      try harness.reader.openConnectionReader()
    }
    #expect(harness.sharedStorage.keychainCallCount == 0)
  }

  @Test func malformedListBlocksTheNextOpen() throws {
    let (_, harness) = makeServer()
    #expect(try harness.reader.openServerReader().loadServers().count == 1)

    setRawDefaultsValue("not-an-array", for: harness.serversKey)

    #expect(throws: SharedStorageReadinessError.malformedServerConfiguration) {
      try harness.reader.openServerReader()
    }
    #expect(throws: SharedStorageReadinessError.malformedServerConfiguration) {
      try harness.reader.openConnectionReader()
    }
  }

  @Test func duplicateIdentifiersBlockTheNextOpen() throws {
    let (server, harness) = makeServer()
    #expect(try harness.reader.openServerReader().loadServers().count == 1)

    let duplicate = ServerConfig(id: server.id, label: "Copy", url: "http://copy.local", version: .v6)
    Defaults[harness.serversKey] = [server, duplicate]

    #expect(throws: SharedStorageReadinessError.malformedServerConfiguration) {
      try harness.reader.openServerReader()
    }
  }

  @Test func missingListUnderCompletionBlocksEveryOpen() {
    let harness = Harness()
    harness.publish(nil)

    #expect(throws: SharedStorageReadinessError.missingServerConfiguration) {
      try harness.reader.openServerReader()
    }
    #expect(throws: SharedStorageReadinessError.missingServerConfiguration) {
      try harness.reader.openConnectionReader()
    }
  }

  @Test func unsupportedCompletionVersionBlocksEveryOpen() {
    let harness = Harness()
    harness.publish([ServerConfig(url: "http://future.local", version: .v6)])
    Defaults[harness.markerKey] = SharedStorageValidation.currentVersion + 1

    let future = SharedStorageValidation.currentVersion + 1
    #expect(throws: SharedStorageReadinessError.unsupportedCompletionVersion(future)) {
      try harness.reader.openServerReader()
    }
    #expect(throws: SharedStorageReadinessError.unsupportedCompletionVersion(future)) {
      try harness.reader.openConnectionReader()
    }
    #expect(harness.sharedStorage.keychainCallCount == 0)
  }

  @Test func malformedCompletionMarkerBlocksEveryOpen() {
    let harness = Harness()
    harness.publish([ServerConfig(url: "http://broken.local", version: .v6)])
    harness.suite.set("one", forKey: harness.markerKey.name)

    #expect(throws: SharedStorageReadinessError.malformedCompletionVersion) {
      try harness.reader.openServerReader()
    }
    #expect(throws: SharedStorageReadinessError.malformedCompletionVersion) {
      try harness.reader.openConnectionReader()
    }
    #expect(harness.sharedStorage.keychainCallCount == 0)
  }

  /// The migration decision stays pending while the reader refuses to publish data.
  @Test func readinessAndReaderAgreeOnAPendingCopy() throws {
    let harness = Harness()
    setRawDefaultsValue("not-an-array", for: harness.serversKey)

    #expect(
      try SharedStorageValidation.readiness(in: harness.suite, suiteName: harness.suiteName) == .pending)
    #expect(throws: SharedStorageAccessError.copyNotPublished) {
      try harness.reader.openServerReader()
    }
  }

  // MARK: - Resolution retry

  @Test func failedLocationResolutionIsRetried() throws {
    let (_, harness) = makeServer()
    harness.sharedStorage.locationError = SharedReaderTestError()

    #expect(throws: SharedReaderTestError.self) {
      try harness.reader.openServerReader()
    }
    #expect(throws: SharedReaderTestError.self) {
      try harness.reader.openConnectionReader()
    }

    harness.sharedStorage.locationError = nil
    #expect(try harness.reader.openServerReader().loadServers().count == 1)
  }

  @Test func failedCredentialResolutionIsRetried() throws {
    let (server, harness) = makeServer(credential: "shared-secret")
    harness.sharedStorage.keychainError = SharedReaderTestError()

    #expect(throws: SharedReaderTestError.self) {
      try harness.reader.openConnectionReader()
    }
    #expect(
      try harness.reader.openServerReader().loadServers().map(\.id) == [server.id],
      "credential resolution failure must not block list reads")
    #expect(harness.sharedStorage.keychainCallCount == 1)

    harness.sharedStorage.keychainError = nil
    let connections = try harness.reader.openConnectionReader()
    #expect(try connections.readCredential(for: server.id) == "shared-secret")
    #expect(harness.sharedStorage.keychainCallCount == 2)
  }

  @Test func credentialReadFailureIsNotTreatedAsAbsence() throws {
    let (server, harness) = makeServer(credential: "shared-secret")
    harness.keychain.readErrorStub = SharedReaderTestError()
    let connections = try harness.reader.openConnectionReader()

    #expect(throws: SharedReaderTestError.self) {
      _ = try connections.readCredential(for: server.id)
    }

    harness.keychain.readErrorStub = nil
    let retried = try harness.reader.openConnectionReader()
    #expect(try retried.readCredential(for: server.id) == "shared-secret")
  }

  // MARK: - Capabilities

  @Test func readersExposeOnlyReadCapabilities() throws {
    let (_, harness) = makeServer()
    let serverReader = try harness.reader.openServerReader()
    let connectionReader = try harness.reader.openConnectionReader()

    #expect((serverReader as Any) is any ServerReading)
    #expect(!((serverReader as Any) is any ConnectionReading))
    #expect(!((serverReader as Any) is any ConnectionStoring))
    #expect(!((serverReader as Any) is any TempUnblockStoring))

    #expect((connectionReader as Any) is any ServerReading)
    #expect((connectionReader as Any) is any ConnectionReading)
    #expect(!((connectionReader as Any) is any ConnectionStoring))
    #expect(!((connectionReader as Any) is any TempUnblockStoring))
  }
}
