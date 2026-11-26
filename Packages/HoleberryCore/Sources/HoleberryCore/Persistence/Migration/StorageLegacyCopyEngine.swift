import Defaults
import Foundation

/// Copies legacy settings and credentials; `StorageLegacyMigrator` checks activation.
/// Tests can create completed copies without activation.
@MainActor
struct StorageLegacyCopyEngine {
  let legacySuite: UserDefaults
  let legacySuiteName: String
  let sharedSuite: UserDefaults
  let sharedSuiteName: String
  let legacyKeychain: any KeychainManaging
  let sharedKeychain: any KeychainManaging

  /// Validates both stores, copies legacy data, then publishes completion.
  /// Requires zero activation in production.
  func refreshBeforeActivation() throws {
    let legacyServers = try StorageLegacyStore.servers(in: legacySuite, suiteName: legacySuiteName)
    // Keep the validated list for cleanup after withdrawing completion.
    let previousSharedServers = try SharedStorageValidation.previousServersForCopy(
      in: sharedSuite,
      suiteName: sharedSuiteName
    )
    // Failed copies stay unpublished and retryable; preserve legacy data.
    Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] = 0
    try importLegacyState(legacyServers, previousSharedServers: previousSharedServers)
    Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] = SharedStorageValidation.currentVersion
  }

  /// Clear stale credentials before replacing the server list.
  private func importLegacyState(
    _ legacyServers: [ServerConfig],
    previousSharedServers: [ServerConfig]
  ) throws {
    try removeStaleSharedCredentials(
      legacyIDs: Set(legacyServers.map(\.id)),
      previousSharedServers: previousSharedServers
    )
    Defaults[.servers(suite: sharedSuite)] = legacyServers
    for server in legacyServers {
      try copyCredential(for: server.id)
    }
  }

  /// Remove shared credentials orphaned by earlier attempts.
  private func removeStaleSharedCredentials(
    legacyIDs: Set<UUID>,
    previousSharedServers: [ServerConfig]
  ) throws {
    let previousSharedIDs = Set(previousSharedServers.map(\.id))
    for staleID in previousSharedIDs.subtracting(legacyIDs) {
      try sharedKeychain.deleteCredential(for: staleID)
    }
  }

  /// Clear the shared credential if absent in legacy.
  private func copyCredential(for serverID: UUID) throws {
    if let credential = try legacyKeychain.readCredential(for: serverID) {
      try sharedKeychain.saveCredential(credential, for: serverID)
    } else {
      try sharedKeychain.deleteCredential(for: serverID)
    }
  }
}
