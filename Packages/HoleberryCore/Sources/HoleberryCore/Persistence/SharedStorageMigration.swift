import Defaults
import Foundation

public enum SharedStorageMigrationError: Error, Equatable, LocalizedError {
  case malformedLegacyConfiguration
  case configurationReadbackMismatch
  case credentialReadbackMismatch(UUID)
  case sharedCredentialRemovalMismatch(UUID)
  case completionMarkerNotPersisted

  public var errorDescription: String? {
    switch self {
    case .malformedLegacyConfiguration:
      return "Legacy server configuration is malformed."
    case .configurationReadbackMismatch:
      return "Shared server configuration readback did not match the copied value."
    case .credentialReadbackMismatch(let serverID):
      return "Shared credential readback did not match the copied value for server \(serverID.uuidString)."
    case .sharedCredentialRemovalMismatch(let serverID):
      return "Shared credential removal was not persisted for server \(serverID.uuidString)."
    case .completionMarkerNotPersisted:
      return "Migration completion marker was not persisted."
    }
  }
}

/// Copies configuration and credentials from the
/// legacy stores into the shared App Group stores. Temporary-unblock records
/// stay in app-local defaults and are never read or written by this migration.
///
/// The legacy stores are read-only inputs and are preserved. Completion is
/// recorded only after every copy is verified by typed readback. A failed
/// import throws its original error before completion is recorded, so the
/// partial shared writes are not published to the app; the next attempt
/// repeats the copy from the current legacy state.
@MainActor
public final class SharedStorageMigration {
  /// The migration generation this build expects. Starts at 1 and is incremented
  /// when the shared stores need a new migration generation.
  ///
  /// Activation and completion are both recorded against this value, so bumping
  /// it makes existing installs run `migrate()` again. Only version zero imports
  /// the legacy stores; later generations change shared data in place so edits
  /// made after the first migration survive.
  public static let currentVersion = 1

  private let legacySuite: UserDefaults
  private let sharedSuite: UserDefaults
  private let sharedSuiteName: String
  private let legacyKeychain: any KeychainManaging
  private let sharedKeychain: any KeychainManaging

  public init(
    legacySuite: UserDefaults,
    sharedSuite: UserDefaults,
    sharedSuiteName: String,
    legacyKeychain: any KeychainManaging,
    sharedKeychain: any KeychainManaging
  ) {
    self.legacySuite = legacySuite
    self.sharedSuite = sharedSuite
    self.sharedSuiteName = sharedSuiteName
    self.legacyKeychain = legacyKeychain
    self.sharedKeychain = sharedKeychain
  }

  public static func isComplete(in suite: UserDefaults) -> Bool {
    Defaults[.sharedStorageMigrationVersion(suite: suite)] >= currentVersion
  }

  /// Whether the legacy standard suite already activated `currentVersion`.
  public static func isCurrentVersionActivated(in legacySuite: UserDefaults) -> Bool {
    Defaults[.sharedStorageActivatedVersion(suite: legacySuite)] >= currentVersion
  }

  /// Records `currentVersion` in the legacy standard suite after a successful
  /// migration.
  public static func markActivated(in legacySuite: UserDefaults) {
    Defaults[.sharedStorageActivatedVersion(suite: legacySuite)] = currentVersion
  }

  public func migrate() throws {
    try migrate(targetVersion: Self.currentVersion)
  }

  /// Applies every step needed to reach `targetVersion`. Internal so tests can
  /// exercise a generation bump before this build ships with one.
  func migrate(targetVersion: Int) throws {
    let completedVersion = Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)]
    guard completedVersion < targetVersion else { return }

    if completedVersion == 0 {
      try importLegacyState()
    }
    try markComplete(targetVersion: targetVersion, previousVersion: completedVersion)
  }

  /// Order matters: stale cleanup runs before the copy so credentials left by an
  /// earlier attempt cannot outlive a server that legacy data no longer has.
  private func importLegacyState() throws {
    let legacyServers = try validatedLegacyServers()
    try removeStaleSharedState(legacyIDs: Set(legacyServers.map(\.id)))
    try copyConfiguration(legacyServers)
    for server in legacyServers {
      try copyCredential(for: server.id)
    }
  }

  /// Strict decode: one bad element rejects the whole array instead of importing
  /// a silently shortened server list.
  private func validatedLegacyServers() throws -> [ServerConfig] {
    do {
      return try Defaults.Keys.strictlyDecodedArray(.servers(suite: legacySuite))
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageMigrationError.malformedLegacyConfiguration
    }
  }

  /// Deletes credentials orphaned by an earlier incomplete attempt. Legacy data
  /// is never removed, only shared entries the current legacy set lacks.
  private func removeStaleSharedState(legacyIDs: Set<UUID>) throws {
    let previousSharedIDs = Set(Defaults[.servers(suite: sharedSuite)].map(\.id))
    for staleID in previousSharedIDs.subtracting(legacyIDs) {
      try removeSharedCredentialIfPresent(for: staleID)
    }
  }

  /// Writes the array and verifies it by readback. The completion marker is not
  /// written yet, so a rejected write leaves a retryable state.
  private func copyConfiguration(_ servers: [ServerConfig]) throws {
    Defaults[.servers(suite: sharedSuite)] = servers
    guard let persisted = try? persistedServers(), configsMatch(persisted, servers) else {
      throw SharedStorageMigrationError.configurationReadbackMismatch
    }
  }

  /// Reads the persistent domain, not registered defaults, so a fallback value
  /// cannot mask a failed write. Success is not a disk-durability guarantee.
  private func persistedServers() throws -> [ServerConfig] {
    try Defaults.Keys.strictlyDecodedPersistedArray(
      .servers(suite: sharedSuite),
      suiteName: sharedSuiteName
    )
  }

  /// An absent legacy secret clears any shared copy from an earlier attempt; a
  /// present one is verified by readback before the run continues.
  private func copyCredential(for serverID: UUID) throws {
    let credential = try legacyKeychain.readCredential(for: serverID)
    if let credential {
      try sharedKeychain.saveCredential(credential, for: serverID)
      guard try sharedKeychain.readCredential(for: serverID) == credential else {
        throw SharedStorageMigrationError.credentialReadbackMismatch(serverID)
      }
    } else {
      try removeSharedCredentialIfPresent(for: serverID)
    }
  }

  /// Written last, after every copy verified. A rejected marker write restores
  /// the previous generation so the import stays retryable.
  private func markComplete(targetVersion: Int, previousVersion: Int) throws {
    Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] = targetVersion
    guard Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] >= targetVersion else {
      // Keep the last verified generation instead of claiming a fresh start.
      Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] = previousVersion
      throw SharedStorageMigrationError.completionMarkerNotPersisted
    }
  }

  /// Reads first so repeat attempts stay idempotent, then verifies the delete:
  /// cleanup that fails silently would leave an old secret in shared storage.
  private func removeSharedCredentialIfPresent(for serverID: UUID) throws {
    guard try sharedKeychain.readCredential(for: serverID) != nil else { return }
    try sharedKeychain.deleteCredential(for: serverID)
    guard try sharedKeychain.readCredential(for: serverID) == nil else {
      throw SharedStorageMigrationError.sharedCredentialRemovalMismatch(serverID)
    }
  }

  /// Compares every stored field because `ServerConfig.==` compares only IDs; a
  /// changed URL or label would otherwise pass as a successful copy.
  private func configsMatch(_ lhs: [ServerConfig], _ rhs: [ServerConfig]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { configFieldsMatch($0.0, $0.1) }
  }

  /// Field-by-field equality; display metadata must round-trip too.
  private func configFieldsMatch(_ lhs: ServerConfig, _ rhs: ServerConfig) -> Bool {
    lhs.id == rhs.id
      && lhs.label == rhs.label
      && lhs.icon == rhs.icon
      && lhs.url == rhs.url
      && lhs.version == rhs.version
  }
}
