import Defaults
import Foundation

/// Copies legacy settings and credentials into the App Group.
///
/// Internal on purpose: production reaches the copy only through
/// `StorageLegacyMigrator.runIfNeeded()`, which enforces activation history. Tests use
/// this seam to publish intermediate states, such as a completed copy that was
/// never activated.
@MainActor
struct StorageLegacyCopyEngine {
  let legacySuite: UserDefaults
  let legacySuiteName: String
  let sharedSuite: UserDefaults
  let sharedSuiteName: String
  let legacyKeychain: any KeychainManaging
  let sharedKeychain: any KeychainManaging

  /// Refreshes a compatible shared copy from the still-authoritative legacy store.
  /// The caller must verify activation version zero before calling this method.
  func refreshBeforeActivation() throws {
    // Validate both stores before resetting the completion marker.
    _ = try StorageLegacyStore.servers(in: legacySuite, suiteName: legacySuiteName)
    _ = try SharedStorageValidation.readiness(in: sharedSuite, suiteName: sharedSuiteName)
    // A completed copy may predate edits made during legacy fallback. Withdraw
    // readiness before any changes, then publish completion after a fresh import.
    Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] = 0
    try migrate()
  }

  /// Copies legacy settings, then publishes the completion marker last.
  func migrate() throws {
    let markerKey = Defaults.Keys.sharedStorageMigrationVersion(suite: sharedSuite)
    let completedVersion: Int
    do {
      completedVersion = try PersistedStartupValue.version(markerKey, suiteName: sharedSuiteName) ?? 0
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageReadinessError.malformedCompletionVersion
    }
    guard completedVersion >= 0, completedVersion <= SharedStorageValidation.currentVersion else {
      throw SharedStorageReadinessError.unsupportedCompletionVersion(completedVersion)
    }
    guard completedVersion < SharedStorageValidation.currentVersion else { return }

    if completedVersion == 0 {
      try importLegacyState()
    }
    Defaults[markerKey] = SharedStorageValidation.currentVersion
  }

  /// Clear stale credentials before replacing the previous server list.
  private func importLegacyState() throws {
    let legacyServers = try StorageLegacyStore.servers(in: legacySuite, suiteName: legacySuiteName)
    try removeStaleSharedCredentials(legacyIDs: Set(legacyServers.map(\.id)))
    Defaults[.servers(suite: sharedSuite)] = legacyServers
    for server in legacyServers {
      try copyCredential(for: server.id)
    }
  }

  /// Remove shared credentials orphaned by an earlier attempt.
  private func removeStaleSharedCredentials(legacyIDs: Set<UUID>) throws {
    let previousSharedServers: [ServerConfig]
    do {
      previousSharedServers = try PersistedStartupValue.servers(in: sharedSuite, suiteName: sharedSuiteName) ?? []
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageReadinessError.malformedServerConfiguration
    }
    let previousSharedIDs = Set(previousSharedServers.map(\.id))
    for staleID in previousSharedIDs.subtracting(legacyIDs) {
      try removeSharedCredentialIfPresent(for: staleID)
    }
  }

  /// Clear any earlier shared copy when the legacy credential is absent.
  private func copyCredential(for serverID: UUID) throws {
    if let credential = try legacyKeychain.readCredential(for: serverID) {
      try sharedKeychain.saveCredential(credential, for: serverID)
    } else {
      try removeSharedCredentialIfPresent(for: serverID)
    }
  }

  private func removeSharedCredentialIfPresent(for serverID: UUID) throws {
    try sharedKeychain.deleteCredential(for: serverID)
  }
}
