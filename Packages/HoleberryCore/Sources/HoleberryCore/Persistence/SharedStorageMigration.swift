import Defaults
import Foundation

public enum SharedStorageMigrationError: Error, Equatable, LocalizedError {
  case malformedLegacyConfiguration
  case malformedActivationRecord

  public var errorDescription: String? {
    switch self {
    case .malformedLegacyConfiguration:
      return "Legacy server configuration is malformed."
    case .malformedActivationRecord:
      return "The app-local activation record is malformed."
    }
  }
}

public enum SharedStorageReadiness: Equatable {
  case pending
  case ready
}

/// Invalid shared storage requires recovery.
public enum SharedStorageReadinessError: Error, Equatable, LocalizedError {
  case malformedCompletionVersion
  case unsupportedCompletionVersion(Int)
  case missingServerConfiguration
  case malformedServerConfiguration

  public var errorDescription: String? {
    switch self {
    case .malformedCompletionVersion:
      return "The shared storage completion marker is malformed."
    case .unsupportedCompletionVersion(let version):
      return "Shared storage completion version \(version) is not supported by this build."
    case .missingServerConfiguration:
      return "Shared storage reports a completed migration without a saved server configuration."
    case .malformedServerConfiguration:
      return "The shared server configuration is malformed."
    }
  }
}

/// Copies server settings and credentials to the App Group. Temporary unblock records stay local.
/// Failed attempts leave the legacy data intact for retry.
@MainActor
public final class SharedStorageMigration {
  /// The supported shared storage version. Only version zero imports legacy data.
  public static let currentVersion = 1

  private let legacySuite: UserDefaults
  private let legacySuiteName: String
  private let sharedSuite: UserDefaults
  private let sharedSuiteName: String
  private let legacyKeychain: any KeychainManaging
  private let sharedKeychain: any KeychainManaging

  public init(
    legacySuite: UserDefaults,
    legacySuiteName: String,
    sharedSuite: UserDefaults,
    sharedSuiteName: String,
    legacyKeychain: any KeychainManaging,
    sharedKeychain: any KeychainManaging
  ) {
    self.legacySuite = legacySuite
    self.legacySuiteName = legacySuiteName
    self.sharedSuite = sharedSuite
    self.sharedSuiteName = sharedSuiteName
    self.legacyKeychain = legacyKeychain
    self.sharedKeychain = sharedKeychain
  }

  /// Readiness requires a persisted completion marker and a valid saved server list.
  /// An explicitly saved empty list is valid.
  public static func readiness(
    in suite: UserDefaults,
    suiteName: String
  ) throws -> SharedStorageReadiness {
    let markerKey = Defaults.Keys.sharedStorageMigrationVersion(suite: suite)
    let version: Int
    do {
      version = try PersistedStartupValue.version(markerKey, suiteName: suiteName) ?? 0
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageReadinessError.malformedCompletionVersion
    }

    guard version != 0 else { return .pending }
    guard version == currentVersion else {
      throw SharedStorageReadinessError.unsupportedCompletionVersion(version)
    }

    let savedServers: [ServerConfig]?
    do {
      savedServers = try PersistedStartupValue.servers(in: suite, suiteName: suiteName)
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageReadinessError.malformedServerConfiguration
    }
    guard savedServers != nil else {
      throw SharedStorageReadinessError.missingServerConfiguration
    }
    return .ready
  }

  /// Reads persisted activation history. Zero means no prior activation. Invalid values throw.
  public static func activatedVersion(in legacySuite: UserDefaults, suiteName: String) throws -> Int {
    let key = Defaults.Keys.sharedStorageActivatedVersion(suite: legacySuite)
    let version: Int
    do {
      version = try PersistedStartupValue.version(key, suiteName: suiteName) ?? 0
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageMigrationError.malformedActivationRecord
    }
    guard version >= 0 else {
      throw SharedStorageMigrationError.malformedActivationRecord
    }
    return version
  }

  /// Records `currentVersion` in app-local defaults.
  public static func markActivated(in legacySuite: UserDefaults) {
    Defaults[.sharedStorageActivatedVersion(suite: legacySuite)] = currentVersion
  }

  /// Copies legacy settings, then publishes the completion marker last.
  public func migrate() throws {
    let markerKey = Defaults.Keys.sharedStorageMigrationVersion(suite: sharedSuite)
    let completedVersion: Int
    do {
      completedVersion = try PersistedStartupValue.version(markerKey, suiteName: sharedSuiteName) ?? 0
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageReadinessError.malformedCompletionVersion
    }
    guard completedVersion >= 0, completedVersion <= Self.currentVersion else {
      throw SharedStorageReadinessError.unsupportedCompletionVersion(completedVersion)
    }
    guard completedVersion < Self.currentVersion else { return }

    if completedVersion == 0 {
      try importLegacyState()
    }
    Defaults[markerKey] = Self.currentVersion
  }

  /// Clear stale credentials before replacing the previous server list.
  private func importLegacyState() throws {
    let legacyServers = try Self.legacyServers(in: legacySuite, suiteName: legacySuiteName)
    try removeStaleSharedCredentials(legacyIDs: Set(legacyServers.map(\.id)))
    Defaults[.servers(suite: sharedSuite)] = legacyServers
    for server in legacyServers {
      try copyCredential(for: server.id)
    }
  }

  /// Validates the saved list for both import and writable fallback.
  public static func legacyServers(in suite: UserDefaults, suiteName: String) throws -> [ServerConfig] {
    do {
      return try PersistedStartupValue.servers(in: suite, suiteName: suiteName) ?? []
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageMigrationError.malformedLegacyConfiguration
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
