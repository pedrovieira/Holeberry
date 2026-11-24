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

  /// Validates both stores, withdraws completion, copies the current legacy
  /// state, and publishes completion last.
  ///
  /// Production calls this only when activation history is zero. Tests use it to
  /// publish the copied-but-unactivated intermediate state.
  func refreshBeforeActivation() throws {
    let legacyServers = try StorageLegacyStore.servers(in: legacySuite, suiteName: legacySuiteName)
    // Validate the compatible shared copy before any mutation.
    _ = try SharedStorageValidation.readiness(in: sharedSuite, suiteName: sharedSuiteName)
    // Withdraw readiness before any change. A failure below leaves the copy
    // unpublished and retryable; legacy data stays intact.
    Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] = 0
    try importLegacyState(legacyServers)
    Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] = SharedStorageValidation.currentVersion
  }

  /// Clear stale credentials before replacing the previous server list.
  private func importLegacyState(_ legacyServers: [ServerConfig]) throws {
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
      try sharedKeychain.deleteCredential(for: staleID)
    }
  }

  /// Clear any earlier shared copy when the legacy credential is absent.
  private func copyCredential(for serverID: UUID) throws {
    if let credential = try legacyKeychain.readCredential(for: serverID) {
      try sharedKeychain.saveCredential(credential, for: serverID)
    } else {
      try sharedKeychain.deleteCredential(for: serverID)
    }
  }
}
