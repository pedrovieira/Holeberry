import Defaults
import Foundation

/// Whether the shared copy is ready to read.
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

/// Read-only validation of the App Group copy for startup, migration, and widgets.
public enum SharedStorageValidation {
  /// Supported completion version; zero means pending.
  static let currentVersion = 1

  /// Returns the completed list, or `nil` while pending.
  /// Missing or invalid completed lists throw; saved empty lists are valid.
  static func completedServers(
    in suite: UserDefaults,
    suiteName: String
  ) throws -> [ServerConfig]? {
    let (snapshot, version) = try capturedCopy(in: suite, suiteName: suiteName)
    guard version != 0 else { return nil }
    guard let savedServers = try savedServers(in: snapshot, suite: suite) else {
      throw SharedStorageReadinessError.missingServerConfiguration
    }
    return savedServers
  }

  /// Captures the old list for stale-credential cleanup, including pending copies.
  /// Malformed lists throw; absent lists are valid only while pending.
  static func previousServersForCopy(
    in suite: UserDefaults,
    suiteName: String
  ) throws -> [ServerConfig] {
    let (snapshot, version) = try capturedCopy(in: suite, suiteName: suiteName)
    let savedServers = try savedServers(in: snapshot, suite: suite)
    guard version != 0 else { return savedServers ?? [] }
    guard let savedServers else {
      throw SharedStorageReadinessError.missingServerConfiguration
    }
    return savedServers
  }

  /// Ready requires a persisted completion marker and a valid list, which may be empty.
  public static func readiness(
    in suite: UserDefaults,
    suiteName: String
  ) throws -> SharedStorageReadiness {
    try completedServers(in: suite, suiteName: suiteName) == nil ? .pending : .ready
  }

  /// Validates the marker first so marker errors take precedence over list errors.
  private static func capturedCopy(
    in suite: UserDefaults,
    suiteName: String
  ) throws -> (snapshot: PersistedStartupValue.Snapshot, version: Int) {
    // One snapshot keeps the marker and list consistent across concurrent writes.
    let snapshot = PersistedStartupValue.Snapshot(
      domain: suite.capturedPersistentDomain(named: suiteName)
    )
    let markerKey = Defaults.Keys.sharedStorageMigrationVersion(suite: suite)
    let version: Int
    do {
      version = try PersistedStartupValue.version(markerKey, in: snapshot) ?? 0
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageReadinessError.malformedCompletionVersion
    }
    guard version == 0 || version == currentVersion else {
      throw SharedStorageReadinessError.unsupportedCompletionVersion(version)
    }
    return (snapshot, version)
  }

  private static func savedServers(
    in snapshot: PersistedStartupValue.Snapshot,
    suite: UserDefaults
  ) throws -> [ServerConfig]? {
    do {
      return try PersistedStartupValue.servers(Defaults.Keys.servers(suite: suite), in: snapshot)
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageReadinessError.malformedServerConfiguration
    }
  }
}
