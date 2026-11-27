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
  /// Persistent domain name for reads that exclude registered defaults.
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

/// Selects app storage after migration, or opens completed shared storage for a widget.
@MainActor
public final class AppStorageStartup {
  public enum Policy {
    /// May migrate legacy data, record activation, and use validated legacy fallback.
    case application
    /// Opens only completed shared storage, without migration or legacy access.
    case sharedOnly
  }

  private enum Access {
    case application(any StorageLegacyMigrating)
    case sharedOnly(any SharedStorageProviding)
  }

  public enum Outcome {
    /// Shared storage is ready and authoritative.
    case shared(any AppStorageProviding, activatedNow: Bool)
    /// Shared storage is not activated. Legacy storage serves this launch.
    case legacy(any AppStorageProviding, cause: any Error)
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

  private let access: Access
  private let legacySuite: UserDefaults
  private let legacySuiteName: String
  private let appLocalSuite: UserDefaults
  private let legacyKeychain: any KeychainManaging

  public init(
    migrator: any StorageLegacyMigrating,
    legacySuite: UserDefaults,
    legacySuiteName: String,
    appLocalSuite: UserDefaults,
    legacyKeychain: any KeychainManaging
  ) {
    self.access = .application(migrator)
    self.legacySuite = legacySuite
    self.legacySuiteName = legacySuiteName
    self.appLocalSuite = appLocalSuite
    self.legacyKeychain = legacyKeychain
  }

  public init(
    policy: Policy,
    legacySuite: UserDefaults = .standard,
    legacySuiteName: String = Bundle.main.bundleIdentifier ?? Bundle.appIdentifier,
    appLocalSuite: UserDefaults = .standard,
    legacyKeychain: any KeychainManaging = KeychainManager(),
    sharedStorage: (any SharedStorageProviding)? = nil
  ) {
    self.legacySuite = legacySuite
    self.legacySuiteName = legacySuiteName
    self.appLocalSuite = appLocalSuite
    self.legacyKeychain = legacyKeychain
    switch policy {
    case .application:
      self.access = .application(
        StorageLegacyMigrator(
          legacySuite: legacySuite,
          legacySuiteName: legacySuiteName,
          appLocalSuite: appLocalSuite,
          legacyKeychain: legacyKeychain,
          shared: sharedStorage ?? BundleSharedStorage.app
        )
      )
    case .sharedOnly:
      self.access = .sharedOnly(sharedStorage ?? BundleSharedStorage.widget)
    }
  }

  /// Revalidates the store on every call, including after suspended widget work.
  public func start() -> Outcome {
    switch access {
    case .application(let migrator):
      return startApplication(migrator: migrator)
    case .sharedOnly(let sharedStorage):
      return startSharedOnly(sharedStorage: sharedStorage)
    }
  }

  private func startApplication(migrator: any StorageLegacyMigrating) -> Outcome {
    let result: StorageLegacyMigrationResult
    do {
      result = try migrator.runIfNeeded()
    } catch let failure as StorageLegacyMigrationFailure {
      // Preserve original causes; only pre-activation failures permit fallback.
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

  /// Lists saved servers from completed shared storage without resolving credentials.
  /// Returns `nil` for app startup, pending copies, or invalid shared storage.
  public func sharedServers() -> [ServerConfig]? {
    guard case .sharedOnly(let sharedStorage) = access else { return nil }
    do {
      let location = try sharedStorage.location()
      return try SharedStorageValidation.completedServers(in: location.suite, suiteName: location.suiteName)
    } catch {
      return nil
    }
  }

  /// Opens only completed shared storage: no migration, activation record, or legacy access.
  private func startSharedOnly(sharedStorage: any SharedStorageProviding) -> Outcome {
    do {
      let location = try sharedStorage.location()
      guard try SharedStorageValidation.readiness(in: location.suite, suiteName: location.suiteName) == .ready else {
        return .setupFailure(AppStorageStartupError.migrationDidNotComplete)
      }
      return .shared(
        ConcreteAppStorage(
          sharedDataSuite: location.suite,
          appLocalSuite: appLocalSuite,
          keychain: try sharedStorage.keychain()
        ),
        activatedNow: false
      )
    } catch {
      return .setupFailure(error)
    }
  }

  /// Rechecks this suite for zero activation and a valid or absent server list:
  /// the injected migrator may use another suite.
  private func legacyOutcome(cause: any Error) -> Outcome {
    do {
      guard try StorageLegacyStore.activatedVersion(in: legacySuite, suiteName: legacySuiteName) == 0 else {
        // Shared storage is authoritative; preserve the original failure.
        return .setupFailure(cause)
      }
    } catch {
      return .setupFailure(error)
    }
    do {
      _ = try StorageLegacyStore.servers(in: legacySuite, suiteName: legacySuiteName)
    } catch {
      return .setupFailure(error)
    }
    // Delete credentials only from legacy; keep unblock records app-local.
    return .legacy(
      ConcreteAppStorage(
        sharedDataSuite: legacySuite,
        appLocalSuite: appLocalSuite,
        keychain: legacyKeychain
      ),
      cause: cause
    )
  }
}
