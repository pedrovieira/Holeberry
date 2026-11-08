import Defaults
import Foundation

@MainActor
public protocol SharedStorageMigrating: AnyObject, Sendable {
  func migrate() throws
}

public enum SharedStorageMigrationError: Error, Equatable, LocalizedError {
  case malformedLegacyConfiguration
  case malformedLegacyTemporaryRecords(UUID)
  case configurationReadbackMismatch
  case temporaryRecordsReadbackMismatch(UUID)
  case credentialReadbackMismatch(UUID)
  case sharedCredentialRemovalMismatch(UUID)
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
    case .completionMarkerNotPersisted:
      return "Migration completion marker was not persisted."
    }
  }
}

/// Copies configuration, temporary-unblock records, and credentials from the
/// legacy stores into the shared App Group stores.
///
/// The legacy stores are read-only inputs and are preserved. Completion is
/// recorded only after every copy is verified by typed readback. Retries always
/// use the current legacy state as authoritative.
@MainActor
public final class SharedStorageMigration: SharedStorageMigrating {
  public static let currentVersion = 1

  private let legacySuite: UserDefaults
  private let sharedSuite: UserDefaults
  private let legacyKeychain: any KeychainManaging
  private let sharedKeychain: any KeychainManaging

  public init(
    legacySuite: UserDefaults,
    sharedSuite: UserDefaults,
    legacyKeychain: any KeychainManaging,
    sharedKeychain: any KeychainManaging
  ) {
    self.legacySuite = legacySuite
    self.sharedSuite = sharedSuite
    self.legacyKeychain = legacyKeychain
    self.sharedKeychain = sharedKeychain
  }

  public static func isComplete(in suite: UserDefaults) -> Bool {
    Defaults[.sharedStorageMigrationVersion(suite: suite)] >= currentVersion
  }

  public func migrate() throws {
    guard !Self.isComplete(in: sharedSuite) else { return }

    let legacyServers = try validatedLegacyServers()
    let legacyRecords = try validatedLegacyRecords(for: legacyServers)
    try removeStaleSharedState(legacyIDs: Set(legacyServers.map(\.id)))
    try copyConfiguration(legacyServers)
    try copyRecordsAndCredentials(for: legacyServers, records: legacyRecords)
    try markComplete()
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
      guard Defaults[.tempUnblocks(for: staleID, suite: sharedSuite)].isEmpty else {
        throw SharedStorageMigrationError.temporaryRecordsReadbackMismatch(staleID)
      }
      try removeSharedCredentialIfPresent(for: staleID)
    }
  }

  private func copyConfiguration(_ servers: [ServerConfig]) throws {
    Defaults[.servers(suite: sharedSuite)] = servers
    guard configsMatch(Defaults[.servers(suite: sharedSuite)], servers) else {
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
    guard Defaults[.tempUnblocks(for: serverID, suite: sharedSuite)] == records else {
      throw SharedStorageMigrationError.temporaryRecordsReadbackMismatch(serverID)
    }
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

  private func markComplete() throws {
    Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] = Self.currentVersion
    guard Self.isComplete(in: sharedSuite) else {
      Defaults[.sharedStorageMigrationVersion(suite: sharedSuite)] = 0
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
