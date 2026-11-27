import Defaults
import Foundation

/// Migration outcome and writable storage.
public enum StorageLegacyMigrationResult {
  /// Shared storage was already active; the writer is ready.
  case alreadyActive(any AppStorageProviding)
  /// Shared storage became active; the writer is ready.
  case activatedNow(any AppStorageProviding)
}

/// Why `runIfNeeded` failed to prepare shared storage.
public enum StorageLegacyMigrationFailure: Error {
  /// Zero activation permits startup to validate legacy fallback.
  case beforeActivation(cause: any Error)
  /// Shared corruption, prior cutover, or unreadable history prevents fallback.
  case recoveryRequired(cause: any Error)
}

public enum AppStorageStartupError: Error, Equatable, LocalizedError {
  case completedStoreMarkerMissing
  case migrationDidNotComplete

  public var errorDescription: String? {
    switch self {
    case .completedStoreMarkerMissing:
      return "Shared storage was activated on an earlier launch but reports no completion marker."
    case .migrationDidNotComplete:
      return "The copy to shared storage did not finish."
    }
  }
}

/// App-only migration; never used by the widget.
@MainActor
public protocol StorageLegacyMigrating {
  func runIfNeeded() throws -> StorageLegacyMigrationResult
}

/// Prepares writable App Group storage before startup selects a store.
///
/// Owns activation history, import/refresh, and activation/repair. Only
/// ``StorageLegacyMigrationFailure/beforeActivation(cause:)`` permits startup
/// to validate legacy fallback.
///
/// Idempotent: positive activation skips import on repeat calls.
@MainActor
public struct StorageLegacyMigrator: StorageLegacyMigrating {
  private let legacySuite: UserDefaults
  private let legacySuiteName: String
  private let appLocalSuite: UserDefaults
  private let legacyKeychain: any KeychainManaging
  private let shared: any SharedStorageProviding

  /// - Parameters:
  ///   - legacySuite: Pre-App-Group server store.
  ///   - legacySuiteName: Persistent domain of `legacySuite`.
  ///   - appLocalSuite: Temporary-unblock records, kept app-local by the shared writer.
  ///   - legacyKeychain: Original credentials for migrated connections.
  ///   - shared: App Group location and shared credential store.
  public init(
    legacySuite: UserDefaults,
    legacySuiteName: String,
    appLocalSuite: UserDefaults,
    legacyKeychain: any KeychainManaging,
    shared: any SharedStorageProviding
  ) {
    self.legacySuite = legacySuite
    self.legacySuiteName = legacySuiteName
    self.appLocalSuite = appLocalSuite
    self.legacyKeychain = legacyKeychain
    self.shared = shared
  }

  public func runIfNeeded() throws -> StorageLegacyMigrationResult {
    let activationHistory = Result {
      try StorageLegacyStore.activatedVersion(in: legacySuite, suiteName: legacySuiteName)
    }
    switch activationHistory {
    case .success(let version) where version > 0:
      return try prepareAlreadyActive()
    case .failure(let error):
      return try repairUnreadableHistory(cause: error)
    case .success:
      return try prepareFirstActivation()
    }
  }

  /// Prepares a writer for a completed shared copy. Positive or unreadable activation
  /// forbids fallback: all failures require recovery. Pending copies use `pendingCause`;
  /// other failures retain their cause.
  private func prepareExistingSharedStore(pendingCause: any Error) throws -> any AppStorageProviding {
    let location: SharedStorageLocation
    let readiness: SharedStorageReadiness
    do {
      location = try shared.location()
      readiness = try SharedStorageValidation.readiness(in: location.suite, suiteName: location.suiteName)
    } catch {
      throw StorageLegacyMigrationFailure.recoveryRequired(cause: error)
    }
    guard readiness == .ready else {
      throw StorageLegacyMigrationFailure.recoveryRequired(cause: pendingCause)
    }
    let keychain: any KeychainManaging
    do {
      keychain = try shared.keychain()
    } catch {
      throw StorageLegacyMigrationFailure.recoveryRequired(cause: error)
    }
    return makeStore(location: location, keychain: keychain)
  }

  /// Positive activation reuses the shared copy without reading legacy servers or credentials.
  private func prepareAlreadyActive() throws -> StorageLegacyMigrationResult {
    let store = try prepareExistingSharedStore(
      pendingCause: AppStorageStartupError.completedStoreMarkerMissing)
    return .alreadyActive(store)
  }

  /// Repairs unreadable activation only after the shared copy and keychain resolve.
  private func repairUnreadableHistory(cause activationError: any Error) throws -> StorageLegacyMigrationResult {
    let store = try prepareExistingSharedStore(pendingCause: activationError)
    StorageLegacyStore.markActivated(in: legacySuite)
    return .activatedNow(store)
  }

  /// Zero or absent activation: refresh from legacy, then activate.
  private func prepareFirstActivation() throws -> StorageLegacyMigrationResult {
    let location: SharedStorageLocation
    do {
      location = try shared.location()
    } catch {
      throw StorageLegacyMigrationFailure.beforeActivation(cause: error)
    }

    do {
      _ = try SharedStorageValidation.readiness(in: location.suite, suiteName: location.suiteName)
    } catch {
      // Never overwrite invalid or unsupported shared evidence.
      throw StorageLegacyMigrationFailure.recoveryRequired(cause: error)
    }

    let keychain: any KeychainManaging
    do {
      keychain = try shared.keychain()
    } catch {
      throw StorageLegacyMigrationFailure.beforeActivation(cause: error)
    }

    let copy = StorageLegacyCopyEngine(
      legacySuite: legacySuite,
      legacySuiteName: legacySuiteName,
      sharedSuite: location.suite,
      sharedSuiteName: location.suiteName,
      legacyKeychain: legacyKeychain,
      sharedKeychain: keychain
    )
    do {
      try copy.refreshBeforeActivation()
    } catch {
      // Import failures permit validated writable legacy fallback.
      // Invalid completed copies require recovery (checked above).
      throw StorageLegacyMigrationFailure.beforeActivation(cause: error)
    }

    let readiness: SharedStorageReadiness
    do {
      readiness = try SharedStorageValidation.readiness(in: location.suite, suiteName: location.suiteName)
    } catch {
      throw StorageLegacyMigrationFailure.recoveryRequired(cause: error)
    }
    guard readiness == .ready else {
      throw StorageLegacyMigrationFailure.beforeActivation(cause: AppStorageStartupError.migrationDidNotComplete)
    }

    let store = makeStore(location: location, keychain: keychain)
    StorageLegacyStore.markActivated(in: legacySuite)
    return .activatedNow(store)
  }

  private func makeStore(
    location: SharedStorageLocation,
    keychain: any KeychainManaging
  ) -> any AppStorageProviding {
    ConcreteAppStorage(
      sharedDataSuite: location.suite,
      appLocalSuite: appLocalSuite,
      keychain: keychain,
      legacyKeychain: legacyKeychain
    )
  }
}
