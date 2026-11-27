import Defaults
import Foundation

/// Activation history and legacy configuration errors.
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

/// Strict legacy reads shared by migration and startup fallback validation.
/// Validates data without deciding whether to copy or activate.
enum StorageLegacyStore {
  /// Validates the saved list for both import and writable fallback.
  static func servers(in suite: UserDefaults, suiteName: String) throws -> [ServerConfig] {
    do {
      return try PersistedStartupValue.servers(in: suite, suiteName: suiteName) ?? []
    } catch {
      guard error is DefaultsValueValidationError else { throw error }
      throw SharedStorageMigrationError.malformedLegacyConfiguration
    }
  }

  /// Reads saved activation: zero means never activated; invalid values throw.
  static func activatedVersion(in suite: UserDefaults, suiteName: String) throws -> Int {
    let key = Defaults.Keys.sharedStorageActivatedVersion(suite: suite)
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
  static func markActivated(in suite: UserDefaults) {
    Defaults[.sharedStorageActivatedVersion(suite: suite)] = SharedStorageValidation.currentVersion
  }
}
