import Defaults
import Foundation
import OSLog

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
/// Server lists come from the domain shared with the widget. An explicit
/// connection deletion also removes the original migrated password.
///
/// The two defaults suites are separate dependencies so their locations can move
/// independently. The app shares server configurations with its widget while
/// temporary-unblock records remain in app-local defaults.
@MainActor
public final class ConcreteAppStorage: AppStorageProviding {
  private let sharedDataSuite: UserDefaults
  private let appLocalSuite: UserDefaults
  private let keychain: any KeychainManaging
  private let legacyKeychain: (any KeychainManaging)?

  /// - Parameters:
  ///   - sharedDataSuite: Backing store for server configurations.
  ///   - appLocalSuite: Backing store for temporary-unblock records. `.standard`
  ///     in the app; widgets never write these records.
  ///   - keychain: Credential storage, keyed by server UUID.
  ///   - legacyKeychain: Original credential store for a migrated connection.
  public init(
    sharedDataSuite: UserDefaults,
    appLocalSuite: UserDefaults,
    keychain: any KeychainManaging,
    legacyKeychain: (any KeychainManaging)? = nil
  ) {
    self.sharedDataSuite = sharedDataSuite
    self.appLocalSuite = appLocalSuite
    self.legacyKeychain = legacyKeychain
    self.keychain = keychain
  }

  // MARK: - Server configurations

  /// An unreadable saved list reads as no connections. Startup reports it
  /// separately and blocks editing before any save can replace it.
  public func loadServers() -> [ServerConfig] {
    Defaults[.servers(suite: sharedDataSuite)]
  }

  public func saveServers(_ servers: [ServerConfig]) {
    Defaults[.servers(suite: sharedDataSuite)] = servers
  }

  public func removeServer(id: UUID) throws {
    try keychain.deleteCredential(for: id)
    try legacyKeychain?.deleteCredential(for: id)
    saveServers(loadServers().filter { $0.id != id })
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

// MARK: - Unavailable Storage

/// Storage for a launch where startup found no usable store.
///
/// It reports no connections and refuses every change. Startup blocks editing
/// in this state, so a refused write signals a defect rather than a user path.
@MainActor
public struct UnavailableAppStorage: AppStorageProviding {
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "storage")

  public init() {}

  public func loadServers() -> [ServerConfig] { [] }

  public func saveServers(_ servers: [ServerConfig]) {
    logger.error("Refused to save servers: no storage is available for this launch.")
  }

  public func removeServer(id: UUID) throws {
    throw PiholeServerMutationError.storageUnavailable
  }

  public func readCredential(for serverID: UUID) throws -> String? {
    throw PiholeServerMutationError.storageUnavailable
  }

  public func saveCredential(_ credential: String, for serverID: UUID) throws {
    throw PiholeServerMutationError.storageUnavailable
  }

  public func deleteCredential(for serverID: UUID) throws {
    throw PiholeServerMutationError.storageUnavailable
  }

  public func loadTemporaryUnblocks(for serverID: UUID) -> [TempUnblockRecord] { [] }

  public func saveTemporaryUnblocks(_ records: [TempUnblockRecord], for serverID: UUID) {
    logger.error("Refused to save temporary unblocks: no storage is available for this launch.")
  }
}
