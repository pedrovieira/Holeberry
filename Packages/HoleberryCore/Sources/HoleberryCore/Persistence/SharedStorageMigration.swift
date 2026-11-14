import Defaults
import Foundation
import OSLog

public enum SharedStorageMigrationError: Error, Equatable, LocalizedError {
  case malformedLegacyConfiguration
  case malformedLegacyTemporaryRecords(UUID)
  case configurationReadbackMismatch
  case temporaryRecordsReadbackMismatch(UUID)
  case credentialReadbackMismatch(UUID)
  case sharedCredentialRemovalMismatch(UUID)
  case sharedConfigurationResetFailed
  case completionMarkerNotPersisted

  public var errorDescription: String? {
    switch self {
    case .malformedLegacyConfiguration:
      return "Legacy server configuration is malformed."
    case .malformedLegacyTemporaryRecords(let serverID):
      return "Legacy temporary-unblock records are malformed for server \(serverID.uuidString)."
    case .configurationReadbackMismatch:
      return "Shared server configuration readback did not match the copied value."
    case .temporaryRecordsReadbackMismatch(let serverID):
      return
        "Shared temporary-unblock records readback did not match the copied value for server \(serverID.uuidString)."
    case .credentialReadbackMismatch(let serverID):
      return "Shared credential readback did not match the copied value for server \(serverID.uuidString)."
    case .sharedCredentialRemovalMismatch(let serverID):
      return "Shared credential removal was not persisted for server \(serverID.uuidString)."
    case .sharedConfigurationResetFailed:
      return "Shared server configuration reset was not persisted."
    case .completionMarkerNotPersisted:
      return "Migration completion marker was not persisted."
    }
  }
}

/// Copies configuration, temporary-unblock records, and credentials from the
/// legacy stores into the shared App Group stores.
///
/// The legacy stores are read-only inputs and are preserved. Completion is
/// recorded only after every copy is verified by typed readback. If the copy
/// cannot be verified, the new stores are reset to an empty server
/// configuration instead of exposing partial data; that reset must itself be
/// written and verified before completion is recorded. Retries always use the
/// current legacy state as authoritative until completion is persisted.
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

  private static let logger = Logger(subsystem: Logger.appSubsystem, category: "shared-storage-migration")

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
      do {
        try importLegacyState()
      } catch {
        let message =
          "Legacy storage import failed; starting with empty shared configuration: "
          + error.localizedDescription
        Self.logger.error("\(message, privacy: .public)")
        try discardPartialImport()
      }
    }
    try markComplete(targetVersion: targetVersion, previousVersion: completedVersion)
  }

  private func importLegacyState() throws {
    let legacyServers = try validatedLegacyServers()
    let legacyRecords = try validatedLegacyRecords(for: legacyServers)
    try removeStaleSharedState(legacyIDs: Set(legacyServers.map(\.id)))
    try copyConfiguration(legacyServers)
    try copyRecordsAndCredentials(for: legacyServers, records: legacyRecords)
  }

  /// Removes every shared server and its associated records after a failed
  /// import. A rejected empty write is a genuine storage failure, so it is not
  /// reported as a successful fresh start.
  private func discardPartialImport() throws {
    let previousIDs = Set(Defaults[.servers(suite: sharedSuite)].map(\.id))
    Defaults[.servers(suite: sharedSuite)] = []
    guard let persisted = try? persistedServers(), persisted.isEmpty else {
      throw SharedStorageMigrationError.sharedConfigurationResetFailed
    }

    for serverID in previousIDs {
      Defaults[.tempUnblocks(for: serverID, suite: sharedSuite)] = []
      try? removeSharedCredentialIfPresent(for: serverID)
    }
  }

  private func validatedLegacyServers() throws -> [ServerConfig] {
    do {
      return try Defaults.Keys.strictlyDecodedArray(.servers(suite: legacySuite))
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageMigrationError.malformedLegacyConfiguration
    }
  }

  private func validatedLegacyRecords(
    for servers: [ServerConfig]
  ) throws -> [UUID: [TempUnblockRecord]] {
    var recordsByID: [UUID: [TempUnblockRecord]] = [:]
    for server in servers {
      do {
        recordsByID[server.id] = try Defaults.Keys.strictlyDecodedArray(
          .tempUnblocks(for: server.id, suite: legacySuite)
        )
      } catch {
        guard error is DefaultsValueValidationError else { throw error }
        throw SharedStorageMigrationError.malformedLegacyTemporaryRecords(server.id)
      }
    }
    return recordsByID
  }

  private func removeStaleSharedState(legacyIDs: Set<UUID>) throws {
    let previousSharedIDs = Set(Defaults[.servers(suite: sharedSuite)].map(\.id))
    for staleID in previousSharedIDs.subtracting(legacyIDs) {
      Defaults[.tempUnblocks(for: staleID, suite: sharedSuite)] = []
      guard let persisted = try? persistedTemporaryRecords(for: staleID), persisted.isEmpty else {
        throw SharedStorageMigrationError.temporaryRecordsReadbackMismatch(staleID)
      }
      try removeSharedCredentialIfPresent(for: staleID)
    }
  }

  private func copyConfiguration(_ servers: [ServerConfig]) throws {
    Defaults[.servers(suite: sharedSuite)] = servers
    guard let persisted = try? persistedServers(), configsMatch(persisted, servers) else {
      throw SharedStorageMigrationError.configurationReadbackMismatch
    }
  }

  private func copyRecordsAndCredentials(
    for servers: [ServerConfig],
    records: [UUID: [TempUnblockRecord]]
  ) throws {
    for server in servers {
      try copyTemporaryRecords(records[server.id] ?? [], for: server.id)
      try copyCredential(for: server.id)
    }
  }

  private func copyTemporaryRecords(_ records: [TempUnblockRecord], for serverID: UUID) throws {
    Defaults[.tempUnblocks(for: serverID, suite: sharedSuite)] = records
    guard let persisted = try? persistedTemporaryRecords(for: serverID), persisted == records else {
      throw SharedStorageMigrationError.temporaryRecordsReadbackMismatch(serverID)
    }
  }

  private func persistedServers() throws -> [ServerConfig] {
    try Defaults.Keys.strictlyDecodedPersistedArray(
      .servers(suite: sharedSuite),
      suiteName: sharedSuiteName
    )
  }

  private func persistedTemporaryRecords(for serverID: UUID) throws -> [TempUnblockRecord] {
    try Defaults.Keys.strictlyDecodedPersistedArray(
      .tempUnblocks(for: serverID, suite: sharedSuite),
      suiteName: sharedSuiteName
    )
  }

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

  private func markComplete(targetVersion: Int, previousVersion: Int) throws {
    Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] = targetVersion
    guard Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] >= targetVersion else {
      // Keep the last verified generation instead of claiming a fresh start.
      Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] = previousVersion
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
