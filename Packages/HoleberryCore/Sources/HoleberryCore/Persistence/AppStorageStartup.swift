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

/// Migrates once, then selects shared storage, validated legacy fallback, or recovery.
@MainActor
public final class AppStorageStartup {
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

  private let migrator: any StorageLegacyMigrating
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
    self.migrator = migrator
    self.legacySuite = legacySuite
    self.legacySuiteName = legacySuiteName
    self.appLocalSuite = appLocalSuite
    self.legacyKeychain = legacyKeychain
  }

  public func start() -> Outcome {
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
