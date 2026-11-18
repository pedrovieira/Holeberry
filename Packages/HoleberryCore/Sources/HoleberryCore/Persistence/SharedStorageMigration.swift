import Defaults
import Foundation

public enum SharedStorageMigrationError: Error, Equatable, LocalizedError {
  case malformedLegacyConfiguration
  case configurationReadbackMismatch
  case credentialReadbackMismatch(UUID)
  case sharedCredentialRemovalMismatch(UUID)
  case completionMarkerNotPersisted
  case activationRecordNotPersisted

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
    case .activationRecordNotPersisted:
      return "The local activation record was not persisted."
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

  /// Readiness requires a persisted completion marker and a valid saved server list.
  /// An explicitly saved empty list is valid.
  public static func readiness(
    in suite: UserDefaults,
    suiteName: String
  ) throws -> SharedStorageReadiness {
    let domain = Defaults.Keys.PersistedDomain(suite: suite, name: suiteName)
    let markerKey = Defaults.Keys.sharedStorageMigrationVersion(suite: suite)
    let version: Int
    do {
      version = try domain.strictlyDecodedInt(markerKey) ?? 0
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageReadinessError.malformedCompletionVersion
    }

    guard version != 0 else { return .pending }
    guard version == currentVersion else {
      throw SharedStorageReadinessError.unsupportedCompletionVersion(version)
    }

    do {
      _ = try domain.strictlyDecodedArray(.servers(suite: suite))
    } catch DefaultsValueValidationError.missingPersistedValue {
      throw SharedStorageReadinessError.missingServerConfiguration
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageReadinessError.malformedServerConfiguration
    }
    return .ready
  }

  /// Reads persisted activation history. Zero means no prior activation. Invalid values throw.
  public static func activatedVersion(in legacySuite: UserDefaults, suiteName: String) throws -> Int {
    let key = Defaults.Keys.sharedStorageActivatedVersion(suite: legacySuite)
    let version: Int
    do {
      version = try Defaults.Keys.strictlyDecodedPersistedInt(key, suiteName: suiteName) ?? 0
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageMigrationError.activationRecordNotPersisted
    }
    guard version >= 0 else {
      throw SharedStorageMigrationError.activationRecordNotPersisted
    }
    return version
  }

  /// Records and verifies `currentVersion` in app-local defaults.
  public static func markActivated(in legacySuite: UserDefaults, suiteName: String) throws {
    let key = Defaults.Keys.sharedStorageActivatedVersion(suite: legacySuite)
    Defaults[key] = currentVersion
    let persisted = try? Defaults.Keys.strictlyDecodedPersistedInt(key, suiteName: suiteName)
    guard persisted.flatMap({ $0 }) == currentVersion else {
      throw SharedStorageMigrationError.activationRecordNotPersisted
    }
  }

  public func migrate() throws {
    try migrate(targetVersion: Self.currentVersion)
  }

  /// Lets tests exercise a future version bump.
  func migrate(targetVersion: Int) throws {
    let markerKey = Defaults.Keys.sharedStorageMigrationVersion(suite: sharedSuite)
    let completedVersion: Int
    do {
      completedVersion = try Defaults.Keys.strictlyDecodedPersistedInt(markerKey, suiteName: sharedSuiteName) ?? 0
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageReadinessError.malformedCompletionVersion
    }
    guard completedVersion >= 0 else {
      throw SharedStorageReadinessError.unsupportedCompletionVersion(completedVersion)
    }
    guard completedVersion < targetVersion else { return }

    if completedVersion == 0 {
      try importLegacyState()
    }
    try markComplete(targetVersion: targetVersion, previousVersion: completedVersion)
  }

  /// Clear stale credentials before replacing the previous server list.
  private func importLegacyState() throws {
    let legacyServers = try validatedLegacyServers()
    try removeStaleSharedState(legacyIDs: Set(legacyServers.map(\.id)))
    try copyConfiguration(legacyServers)
    for server in legacyServers {
      try copyCredential(for: server.id)
    }
  }

  /// Reject the import if any server fails to decode.
  private func validatedLegacyServers() throws -> [ServerConfig] {
    do {
      return try Defaults.Keys.strictlyDecodedArray(.servers(suite: legacySuite))
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageMigrationError.malformedLegacyConfiguration
    }
  }

  /// Remove shared credentials orphaned by an earlier attempt.
  private func removeStaleSharedState(legacyIDs: Set<UUID>) throws {
    let previousSharedServers: [ServerConfig]
    do {
      previousSharedServers = try persistedServers()
    } catch DefaultsValueValidationError.missingPersistedValue {
      return
    } catch DefaultsValueValidationError.malformedValue {
      throw SharedStorageReadinessError.malformedServerConfiguration
    }
    let previousSharedIDs = Set(previousSharedServers.map(\.id))
    for staleID in previousSharedIDs.subtracting(legacyIDs) {
      try removeSharedCredentialIfPresent(for: staleID)
    }
  }

  private func copyConfiguration(_ servers: [ServerConfig]) throws {
    Defaults[.servers(suite: sharedSuite)] = servers
    guard let persisted = try? persistedServers(), configsMatch(persisted, servers) else {
      throw SharedStorageMigrationError.configurationReadbackMismatch
    }
  }

  /// Reads the persistent domain to detect rejected writes. Disk writes remain asynchronous.
  private func persistedServers() throws -> [ServerConfig] {
    try Defaults.Keys.strictlyDecodedPersistedArray(
      .servers(suite: sharedSuite),
      suiteName: sharedSuiteName
    )
  }

  /// Clear any earlier shared copy when the legacy credential is absent.
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

  /// Publish completion last. Keep the previous version if readback fails.
  private func markComplete(targetVersion: Int, previousVersion: Int) throws {
    let markerKey = Defaults.Keys.sharedStorageMigrationVersion(suite: sharedSuite)
    Defaults[markerKey] = targetVersion
    let persisted = try? Defaults.Keys.strictlyDecodedPersistedInt(markerKey, suiteName: sharedSuiteName)
    guard persisted.flatMap({ $0 }) == targetVersion else {
      Defaults[markerKey] = previousVersion
      throw SharedStorageMigrationError.completionMarkerNotPersisted
    }
  }

  private func removeSharedCredentialIfPresent(for serverID: UUID) throws {
    guard try sharedKeychain.readCredential(for: serverID) != nil else { return }
    try sharedKeychain.deleteCredential(for: serverID)
    guard try sharedKeychain.readCredential(for: serverID) == nil else {
      throw SharedStorageMigrationError.sharedCredentialRemovalMismatch(serverID)
    }
  }

  /// `ServerConfig.==` compares IDs only.
  private func configsMatch(_ lhs: [ServerConfig], _ rhs: [ServerConfig]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { configFieldsMatch($0.0, $0.1) }
  }

  private func configFieldsMatch(_ lhs: ServerConfig, _ rhs: ServerConfig) -> Bool {
    lhs.id == rhs.id
      && lhs.label == rhs.label
      && lhs.icon == rhs.icon
      && lhs.url == rhs.url
      && lhs.version == rhs.version
  }
}
