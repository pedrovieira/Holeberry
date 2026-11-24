import Foundation

/// Where a launch reads and writes its settings.
public enum AppStorageStartupStatus: Equatable {
  case shared
  case legacy
  case recovery
}

/// Chooses the storage for one launch.
///
/// Migration belongs to `StorageLegacyMigrator`; this type only calls the injected
/// migration once, maps its result to the existing outcome surface, and builds
/// legacy fallback when the migrator reports that activation was zero and the
/// copy did not complete. It never copies data, writes activation, or opens the
/// shared store for a second activation decision.
@MainActor
public final class AppStorageStartup {
  public enum Outcome {
    /// Shared storage is ready and authoritative.
    case shared(any ConnectionStoring, activatedNow: Bool)
    /// Shared storage is not activated. Legacy storage serves this launch.
    case legacy(any ConnectionStoring, cause: any Error)
    /// No store passed validation. Settings are not available for this launch.
    case setupFailure(any Error)

    public var status: AppStorageStartupStatus {
      switch self {
      case .shared:
        return .shared
      case .legacy:
        return .legacy
      case .setupFailure:
        return .recovery
      }
    }

    public var storage: (any ConnectionStoring)? {
      switch self {
      case .shared(let storage, _):
        return storage
      case .legacy(let storage, _):
        return storage
      case .setupFailure:
        return nil
      }
    }

    public var activatedNow: Bool {
      switch self {
      case .shared(_, let activatedNow):
        return activatedNow
      case .legacy, .setupFailure:
        return false
      }
    }

    /// The reason this launch is not on ready shared storage, for logs and the setup notice.
    public var problem: (any Error)? {
      switch self {
      case .shared:
        return nil
      case .legacy(_, let cause):
        return cause
      case .setupFailure(let error):
        return error
      }
    }
  }

  private let migrator: any StorageLegacyMigrating
  private let legacySuite: UserDefaults
  private let legacySuiteName: String
  private let legacyKeychain: any KeychainManaging

  public init(
    migrator: any StorageLegacyMigrating,
    legacySuite: UserDefaults,
    legacySuiteName: String,
    legacyKeychain: any KeychainManaging
  ) {
    self.migrator = migrator
    self.legacySuite = legacySuite
    self.legacySuiteName = legacySuiteName
    self.legacyKeychain = legacyKeychain
  }

  public func start() -> Outcome {
    let result: StorageLegacyMigrationResult
    do {
      result = try migrator.runIfNeeded()
    } catch let failure as StorageLegacyMigrationFailure {
      // Only an established zero activation permits fallback. Everything else
      // recovers with the original cause, never a wrapper.
      switch failure {
      case .beforeActivation(let cause):
        return legacyOutcome(cause: cause)
      case .recoveryRequired(let cause):
        return .setupFailure(cause)
      }
    } catch {
      return .setupFailure(error)
    }

    switch result {
    case .alreadyActive(let storage):
      return .shared(storage, activatedNow: false)
    case .activatedNow(let storage):
      return .shared(storage, activatedNow: true)
    }
  }

  /// Validates the current legacy list strictly. A malformed list never becomes
  /// writable storage; a genuinely absent list is a valid fresh install.
  private func legacyOutcome(cause: any Error) -> Outcome {
    do {
      _ = try StorageLegacyStore.servers(in: legacySuite, suiteName: legacySuiteName)
    } catch {
      return .setupFailure(error)
    }
    // Legacy fallback is writable: the legacy keychain is the active store, so a
    // connection deletion touches that one keychain only.
    return .legacy(
      ConcreteConnectionStore(suite: legacySuite, keychain: legacyKeychain),
      cause: cause
    )
  }
}
