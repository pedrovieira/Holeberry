import Defaults
import Foundation
import OSLog

/// Writable connection storage over one defaults suite and a keychain.
///
/// The suite decides which domain a launch reads and writes: the App Group in
/// shared mode, the app's own defaults domain during validated legacy fallback.
/// The constructor is the only place that chooses; callers see capabilities.
@MainActor
public final class ConcreteConnectionStore: ConnectionStoring {
  private let suite: UserDefaults
  private let keychain: any KeychainManaging
  private let legacyKeychain: (any KeychainManaging)?

  /// - Parameters:
  ///   - suite: Backing store for the server list.
  ///   - keychain: Active credential storage, keyed by server UUID.
  ///   - legacyKeychain: Credential store of a migrated connection. Used for
  ///     cleanup on an explicit connection deletion, never as the active copy.
  public init(
    suite: UserDefaults,
    keychain: any KeychainManaging,
    legacyKeychain: (any KeychainManaging)? = nil
  ) {
    self.suite = suite
    self.keychain = keychain
    self.legacyKeychain = legacyKeychain
  }

  // MARK: - Server configurations

  /// An unreadable saved list reads as no connections. Startup reports the
  /// failure separately and blocks editing, so no save replaces the evidence.
  public func loadServers() -> [ServerConfig] {
    Defaults[.servers(suite: suite)]
  }

  public func saveServers(_ servers: [ServerConfig]) {
    Defaults[.servers(suite: suite)] = servers
  }

  /// Deletes the legacy copy first, then the active credential, then the saved
  /// configuration.
  ///
  /// A failure stops the sequence at that step. A legacy cleanup failure leaves
  /// the active connection usable, and a crash between the two credential
  /// deletions leaves a connection without a password rather than an orphaned
  /// password without a connection.
  public func removeServer(id: UUID) throws {
    try legacyKeychain?.deleteCredential(for: id)
    try keychain.deleteCredential(for: id)
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
}

// MARK: - Unavailable Storage

/// Connection storage for a launch where startup found no usable store.
///
/// It reports no connections and refuses every change. Startup blocks editing
/// in this state, so a refused write signals a defect rather than a user path.
@MainActor
public struct UnavailableConnectionStore: ConnectionStoring {
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "storage")

  public init() {}

  public func loadServers() -> [ServerConfig] { [] }

  public func saveServers(_ servers: [ServerConfig]) {
    logger.error("Refused to save servers: no connection storage is available for this launch.")
  }

  public func removeServer(id: UUID) throws {
    throw HoleberryError.storageUnavailable
  }

  public func readCredential(for serverID: UUID) throws -> String? {
    throw HoleberryError.storageUnavailable
  }

  public func saveCredential(_ credential: String, for serverID: UUID) throws {
    throw HoleberryError.storageUnavailable
  }

  public func deleteCredential(for serverID: UUID) throws {
    throw HoleberryError.storageUnavailable
  }
}
