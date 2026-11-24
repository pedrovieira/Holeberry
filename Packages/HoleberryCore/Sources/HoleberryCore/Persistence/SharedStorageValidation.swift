import Defaults
import Foundation

/// How much of the shared copy a consumer may read.
enum SharedStorageReadiness: Equatable {
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

/// Shared-copy validation with no migration or legacy responsibility.
///
/// App startup, the legacy migrator, and the widget reader all validate the same
/// App Group copy here. The helper never reads the legacy suite or keychain and
/// never writes.
enum SharedStorageValidation {
  /// The supported shared storage version. Only zero means not published.
  static let currentVersion = 1

  /// Reads one shared open: the current completion marker and the persisted list.
  ///
  /// Returns `nil` while the copy is not published. Once the completion marker is
  /// current, the copy must hold a valid list: a missing, partially decoded, or
  /// duplicated list throws. An explicitly saved empty list is valid.
  static func completedServers(
    in suite: UserDefaults,
    suiteName: String
  ) throws -> [ServerConfig]? {
    // One capture for the whole decision: the marker and the list come from the
    // same persistent-domain snapshot, so a concurrent rewrite cannot produce a
    // result built from two different states.
    let snapshot = PersistedStartupValue.Snapshot(suite: suite, suiteName: suiteName)
    let markerKey = Defaults.Keys.sharedStorageMigrationVersion(suite: suite)
    let version: Int
    do {
      version = try PersistedStartupValue.version(markerKey, in: snapshot) ?? 0
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageReadinessError.malformedCompletionVersion
    }

    guard version != 0 else { return nil }
    guard version == currentVersion else {
      throw SharedStorageReadinessError.unsupportedCompletionVersion(version)
    }

    let savedServers: [ServerConfig]?
    do {
      savedServers = try PersistedStartupValue.servers(Defaults.Keys.servers(suite: suite), in: snapshot)
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageReadinessError.malformedServerConfiguration
    }
    guard let savedServers else {
      throw SharedStorageReadinessError.missingServerConfiguration
    }
    return savedServers
  }

  /// Readiness requires a persisted completion marker and a valid saved server list.
  /// An explicitly saved empty list is valid.
  static func readiness(
    in suite: UserDefaults,
    suiteName: String
  ) throws -> SharedStorageReadiness {
    try completedServers(in: suite, suiteName: suiteName) == nil ? .pending : .ready
  }
}
