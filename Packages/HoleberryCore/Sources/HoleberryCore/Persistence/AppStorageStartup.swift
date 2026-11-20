import Foundation

/// Where a launch reads and writes its settings.
public enum AppStorageStartupStatus: Equatable {
  case shared
  case legacy
  case recovery
}

/// App Group location shared with the widget.
public struct SharedStorageLocation {
  public let suite: UserDefaults
  /// Persistent domain of `suite`. `UserDefaults` does not expose this name, and
  /// strict startup reads must exclude registered defaults.
  public let suiteName: String

  public init(suite: UserDefaults, suiteName: String) {
    self.suite = suite
    self.suiteName = suiteName
  }
}

/// The App Group store and the credential store that belongs to it.
@MainActor
public protocol SharedStorageProviding {
  func location() throws -> SharedStorageLocation
  func keychain() throws -> any KeychainManaging
}

public enum AppStorageStartupError: Error, Equatable, LocalizedError {
  case completedStoreMarkerMissing
  case migrationDidNotComplete

  public var errorDescription: String? {
    switch self {
    case .completedStoreMarkerMissing:
      return "Shared storage was activated on an earlier launch but reports no completion marker."
    case .migrationDidNotComplete:
      return "The first copy to shared storage did not finish."
    }
  }
}

/// Chooses the storage for one launch and runs the one-time move to shared storage.
///
/// Two markers keep separate jobs: the completion marker in the shared store says
/// what the widget may read; the app-local activation record says whether shared
/// storage replaced legacy storage. Once activation is recorded, shared storage is
/// authoritative and missing or unreadable shared data never re-imports legacy data.
@MainActor
public final class AppStorageStartup {
  public enum Outcome {
    /// Shared storage is ready and authoritative.
    case shared(ConcreteAppStorage, activatedNow: Bool)
    /// The first copy is still pending. Legacy storage serves this launch.
    case legacy(ConcreteAppStorage, cause: any Error)
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

    public var storage: (any AppStorageProviding)? {
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

  private let legacySuite: UserDefaults
  private let legacySuiteName: String
  private let appLocalSuite: UserDefaults
  private let legacyKeychain: any KeychainManaging
  private let sharedStorage: any SharedStorageProviding

  public init(
    legacySuite: UserDefaults,
    legacySuiteName: String,
    appLocalSuite: UserDefaults,
    legacyKeychain: any KeychainManaging,
    sharedStorage: any SharedStorageProviding
  ) {
    self.legacySuite = legacySuite
    self.legacySuiteName = legacySuiteName
    self.appLocalSuite = appLocalSuite
    self.legacyKeychain = legacyKeychain
    self.sharedStorage = sharedStorage
  }

  public func start() -> Outcome {
    let activation = Result {
      try SharedStorageMigration.activatedVersion(in: legacySuite, suiteName: legacySuiteName)
    }

    let location: SharedStorageLocation
    do {
      location = try sharedStorage.location()
    } catch {
      guard !hasPriorCutover(activation) else { return .setupFailure(error) }
      return legacyOutcome(cause: error)
    }

    let readiness: SharedStorageReadiness
    do {
      readiness = try SharedStorageMigration.readiness(in: location.suite, suiteName: location.suiteName)
    } catch {
      return .setupFailure(error)
    }

    switch (readiness, activation) {
    case (.ready, .success(let version)) where version > 0:
      return sharedOutcome(location: location, activatedNow: false)
    case (.ready, _):
      // Verified shared storage repairs a missing or unreadable activation record.
      SharedStorageMigration.markActivated(in: legacySuite)
      return sharedOutcome(location: location, activatedNow: true)
    case (.pending, .success(0)):
      return completeFirstCopy(location: location)
    case (.pending, .success):
      return .setupFailure(AppStorageStartupError.completedStoreMarkerMissing)
    case (.pending, .failure(let error)):
      return .setupFailure(error)
    }
  }

  /// An unfinished first copy falls back to legacy storage; a recorded cutover
  /// blocks the fallback so stale legacy data cannot reappear.
  private func completeFirstCopy(location: SharedStorageLocation) -> Outcome {
    let sharedKeychain: any KeychainManaging
    do {
      sharedKeychain = try sharedStorage.keychain()
    } catch {
      return legacyOutcome(cause: error)
    }

    let migration = SharedStorageMigration(
      legacySuite: legacySuite,
      legacySuiteName: legacySuiteName,
      sharedSuite: location.suite,
      sharedSuiteName: location.suiteName,
      legacyKeychain: legacyKeychain,
      sharedKeychain: sharedKeychain
    )

    var copyFailure: (any Error)?
    do {
      try migration.migrate()
    } catch {
      copyFailure = error
    }

    // Verified completion takes precedence over an import error.
    do {
      guard try SharedStorageMigration.readiness(in: location.suite, suiteName: location.suiteName) == .ready else {
        return legacyOutcome(cause: copyFailure ?? AppStorageStartupError.migrationDidNotComplete)
      }
    } catch {
      return .setupFailure(error)
    }

    SharedStorageMigration.markActivated(in: legacySuite)
    return .shared(
      makeStorage(sharedSuite: location.suite, keychain: sharedKeychain),
      activatedNow: true
    )
  }

  private func sharedOutcome(location: SharedStorageLocation, activatedNow: Bool) -> Outcome {
    do {
      return .shared(
        makeStorage(sharedSuite: location.suite, keychain: try sharedStorage.keychain()),
        activatedNow: activatedNow
      )
    } catch {
      return .setupFailure(error)
    }
  }

  private func legacyOutcome(cause: any Error) -> Outcome {
    do {
      _ = try SharedStorageMigration.legacyServers(in: legacySuite, suiteName: legacySuiteName)
    } catch {
      return .setupFailure(error)
    }
    return .legacy(
      ConcreteAppStorage(
        sharedDataSuite: legacySuite,
        appLocalSuite: appLocalSuite,
        keychain: legacyKeychain
      ),
      cause: cause
    )
  }

  private func makeStorage(sharedSuite: UserDefaults, keychain: any KeychainManaging) -> ConcreteAppStorage {
    ConcreteAppStorage(
      sharedDataSuite: sharedSuite,
      appLocalSuite: appLocalSuite,
      keychain: keychain,
      legacyKeychain: legacyKeychain
    )
  }

  /// Unreadable history blocks legacy import.
  private func hasPriorCutover(_ activation: Result<Int, any Error>) -> Bool {
    switch activation {
    case .success(let version):
      return version > 0
    case .failure:
      return true
    }
  }
}
