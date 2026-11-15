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

  func readCredential(for serverID: UUID) throws -> String?
  func saveCredential(_ credential: String, for serverID: UUID) throws
  func deleteCredential(for serverID: UUID) throws

  func loadTemporaryUnblocks(for serverID: UUID) -> [TempUnblockRecord]
  func saveTemporaryUnblocks(_ records: [TempUnblockRecord], for serverID: UUID)
}

// MARK: - Concrete Implementation

/// Thin adapter over the existing typed `Defaults` keys and `KeychainManaging`.
///
/// Every load reads the backing store; there is no cache. The adapter does no
/// normalization, validation, expiry calculation, or error conversion — those
/// stay with the callers. Construction has no side effects.
///
/// The two defaults suites are separate dependencies so their locations can move
/// independently. Both are `.standard` in the current app and no sharing is set
/// up yet.
@MainActor
public final class ConcreteAppStorage: AppStorageProviding {
  private let sharedDataSuite: UserDefaults
  private let appLocalSuite: UserDefaults
  private let keychain: any KeychainManaging

  /// - Parameters:
  ///   - sharedDataSuite: Backing store for server configurations. Uses `.standard`
  ///     today; the widget work (PR #59) will pass a shared suite here.
  ///   - appLocalSuite: Backing store for temporary-unblock records. `.standard`
  ///     before and after the widget work.
  ///   - keychain: Credential storage, keyed by server UUID.
  public init(
    sharedDataSuite: UserDefaults,
    appLocalSuite: UserDefaults,
    keychain: any KeychainManaging
  ) {
    self.sharedDataSuite = sharedDataSuite
    self.appLocalSuite = appLocalSuite
    self.keychain = keychain
  }

  // MARK: - Server configurations

  public func loadServers() -> [ServerConfig] {
    Defaults[.servers(suite: sharedDataSuite)]
  }

  public func saveServers(_ servers: [ServerConfig]) {
    Defaults[.servers(suite: sharedDataSuite)] = servers
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
