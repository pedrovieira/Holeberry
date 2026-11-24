import Defaults
import Foundation

/// What one migration step produced.
public enum StorageLegacyMigrationResult {
  /// Shared storage was already active. The writer is ready for this launch.
  case alreadyActive(any ConnectionStoring)
  /// Shared storage became active in this step. The writer is ready for this launch.
  case activatedNow(any ConnectionStoring)
}

/// Why `runIfNeeded` refused to prepare shared storage.
public enum StorageLegacyMigrationFailure: Error {
  /// Activation history was zero, so startup may validate legacy and fall back.
  case beforeActivation(cause: any Error)
  /// Shared corruption, prior cutover, or unreadable history prevents fallback.
  case recoveryRequired(cause: any Error)
}

/// The app-only migration seam. The widget never runs or references this.
@MainActor
public protocol StorageLegacyMigrating {
  func runIfNeeded() throws -> StorageLegacyMigrationResult
}

/// Prepares the shared App Group copy for the app, once per launch.
///
/// The operation is app-only and explicitly called during startup before the
/// launch chooses its store. It owns activation history, shared preparation,
/// import/refresh, activation/repair, and the resulting writable connection
/// store. It throws typed failures instead of choosing fallback: only
/// ``StorageLegacyMigrationFailure/beforeActivation(cause:)`` lets startup validate and
/// use legacy storage.
///
/// Repeat calls are idempotent: a positive activation record skips import.
@MainActor
public struct StorageLegacyMigrator: StorageLegacyMigrating {
  private let legacySuite: UserDefaults
  private let legacySuiteName: String
  private let legacyKeychain: any KeychainManaging
  private let shared: any SharedStorageProviding

  public init(
    legacySuite: UserDefaults,
    legacySuiteName: String,
    legacyKeychain: any KeychainManaging,
    shared: any SharedStorageProviding
  ) {
    self.legacySuite = legacySuite
    self.legacySuiteName = legacySuiteName
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

  /// Positive activation: open the existing copy. No legacy server or credential
  /// read happens; activation history was already read.
  private func prepareAlreadyActive() throws -> StorageLegacyMigrationResult {
    let location = try openSharedLocation()
    let readiness: SharedStorageReadiness
    do {
      readiness = try SharedStorageValidation.readiness(in: location.suite, suiteName: location.suiteName)
    } catch {
      throw StorageLegacyMigrationFailure.recoveryRequired(cause: error)
    }
    guard readiness == .ready else {
      throw StorageLegacyMigrationFailure.recoveryRequired(cause: AppStorageStartupError.completedStoreMarkerMissing)
    }
    let keychain = try resolveSharedKeychainForRecovery()
    return .alreadyActive(makeStore(location: location, keychain: keychain))
  }

  /// Unreadable activation: open the existing copy and repair the record.
  /// The repair happens only after the copy and its keychain resolve.
  private func repairUnreadableHistory(cause activationError: any Error) throws -> StorageLegacyMigrationResult {
    let location = try openSharedLocation()
    let readiness: SharedStorageReadiness
    do {
      readiness = try SharedStorageValidation.readiness(in: location.suite, suiteName: location.suiteName)
    } catch {
      throw StorageLegacyMigrationFailure.recoveryRequired(cause: error)
    }
    guard readiness == .ready else {
      throw StorageLegacyMigrationFailure.recoveryRequired(cause: activationError)
    }
    let keychain = try resolveSharedKeychainForRecovery()
    let store = makeStore(location: location, keychain: keychain)
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
      // Invalid or unsupported shared evidence: never rewrite it.
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
      // Refresh failures are import failures: startup validates legacy again
      // and may use it writable. Only invalid completed evidence, checked
      // above, is recovery.
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

  private func openSharedLocation() throws -> SharedStorageLocation {
    do {
      return try shared.location()
    } catch {
      throw StorageLegacyMigrationFailure.recoveryRequired(cause: error)
    }
  }

  /// Resolves the shared keychain for a prior cutover. A failure is recovery:
  /// activation history is positive or unreadable, so fallback is never allowed.
  private func resolveSharedKeychainForRecovery() throws -> any KeychainManaging {
    do {
      return try shared.keychain()
    } catch {
      throw StorageLegacyMigrationFailure.recoveryRequired(cause: error)
    }
  }

  private func makeStore(
    location: SharedStorageLocation,
    keychain: any KeychainManaging
  ) -> any ConnectionStoring {
    ConcreteConnectionStore(
      suite: location.suite,
      keychain: keychain,
      legacyKeychain: legacyKeychain
    )
  }
}
