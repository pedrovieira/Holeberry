import Defaults
import Foundation

// MARK: - Protocol

/// Typed persistence for the three data types the app stores.
///
/// Callers never choose a defaults suite, a defaults key, or a Keychain
/// namespace: those decisions belong to the implementation. Methods are
/// synchronous and main-actor isolated, matching their current consumers.
@MainActor
public protocol AppStorageProviding {
  func loadServers() -> [ServerConfig]
  func saveServers(_ servers: [ServerConfig])
  func removeServer(id: UUID) throws

  func readCredential(for serverID: UUID) throws -> String?
  func saveCredential(_ credential: String, for serverID: UUID) throws
  func deleteCredential(for serverID: UUID) throws

  func loadTemporaryUnblocks(for serverID: UUID) -> [TempUnblockRecord]
  func saveTemporaryUnblocks(_ records: [TempUnblockRecord], for serverID: UUID)
}

// MARK: - Concrete Implementation

/// Thin adapter over the existing typed `Defaults` keys and `KeychainManaging`.
///
/// Server lists come from the persistent domain shared with the widget.
/// An explicit connection deletion also removes the original migrated password.
///
/// The two defaults suites are separate dependencies so their locations can move
/// independently. The app shares server configurations with its widget while
/// temporary-unblock records remain in app-local defaults.
@MainActor
public final class ConcreteAppStorage: AppStorageProviding {
  private let sharedDataSuite: UserDefaults
  private let sharedDataSuiteName: String
  private let appLocalSuite: UserDefaults
  private let keychain: any KeychainManaging
  private let legacyKeychain: (any KeychainManaging)?

  /// - Parameters:
  ///   - sharedDataSuite: Shared App Group backing store for server configurations.
  ///   - sharedDataSuiteName: Persistent domain for the server list.
  ///   - legacyKeychain: Original credential store for a migrated connection.
  ///   - appLocalSuite: Backing store for temporary-unblock records. `.standard`
  ///     in the app; widgets use a no-write empty store for these records.
  ///   - keychain: Credential storage, keyed by server UUID.
  public init(
    sharedDataSuite: UserDefaults,
    sharedDataSuiteName: String,
    appLocalSuite: UserDefaults,
    keychain: any KeychainManaging,
    legacyKeychain: (any KeychainManaging)? = nil
  ) {
    self.sharedDataSuiteName = sharedDataSuiteName
    self.sharedDataSuite = sharedDataSuite
    self.appLocalSuite = appLocalSuite
    self.legacyKeychain = legacyKeychain
    self.keychain = keychain
  }

  // MARK: - Server configurations

  public func loadServers() -> [ServerConfig] {
    (try? persistedServers()) ?? []
  }

  public func saveServers(_ servers: [ServerConfig]) {
    guard (try? persistedServers()) != nil else { return }
    Defaults[.servers(suite: sharedDataSuite)] = servers
  }

  private func persistedServers() throws -> [ServerConfig] {
    try Defaults.Keys.PersistedDomain(suite: sharedDataSuite, name: sharedDataSuiteName)
      .servers(in: sharedDataSuite) ?? []
  }

  public func removeServer(id: UUID) throws {
    let remaining = try persistedServers().filter { $0.id != id }
    let legacyDeletion = Result { try legacyKeychain?.deleteCredential(for: id) }
    try keychain.deleteCredential(for: id)
    try legacyDeletion.get()

    Defaults[.servers(suite: sharedDataSuite)] = remaining
    guard try !persistedServers().contains(where: { $0.id == id }) else {
      throw PiholeServerMutationError.storageUnavailable
    }
  }

  // MARK: - Credentials

  public func readCredential(for serverID: UUID) throws -> String? {
    try keychain.readCredential(for: serverID)
  }

  public func saveCredential(_ credential: String, for serverID: UUID) throws {
    try keychain.saveCredential(credential, for: serverID)
  }

  public func deleteCredential(for serverID: UUID) throws {
    try keychain.deleteCredential(for: serverID)
  }

  // MARK: - Temporary unblock records

  public func loadTemporaryUnblocks(for serverID: UUID) -> [TempUnblockRecord] {
    Defaults[.tempUnblocks(for: serverID, suite: appLocalSuite)]
  }

  public func saveTemporaryUnblocks(_ records: [TempUnblockRecord], for serverID: UUID) {
    Defaults[.tempUnblocks(for: serverID, suite: appLocalSuite)] = records
  }
}
