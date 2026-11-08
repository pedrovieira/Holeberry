import Defaults
import Foundation
import Testing

@testable import HoleberryCore

private struct PersistentChangeTestError: Error {}

@Suite("PiholeServerManager persistent changes")
@MainActor
struct PiholeServerManagerPersistentChangeTests {
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

  private struct PersistentChangeSnapshot {
    let credential: String?
    let servers: [ServerConfig]
  }

  private func makeManager(
    suite: UserDefaults,
    keychain: MockKeychainManager,
    persistentChangeHandler: @escaping () -> Void = {}
  ) -> PiholeServerManager {
    PiholeServerManager(
      keychain: keychain,
      serviceFactory: MockPiholeServiceFactory(),
      versionDetector: MockPiholeVersionDetector(),
      suite: suite,
      persistentChangeHandler: persistentChangeHandler
    )
  }
}
