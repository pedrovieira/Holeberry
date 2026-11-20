import Foundation

@MainActor
public enum AppStorageStartupSelection {
  case useShared(UserDefaults, didActivate: Bool)
  /// The first migration is pending. Retry on the next launch.
  case useLegacy(cause: any Error)
  /// Recovery blocks writes and legacy import.
  case unavailable(cause: any Error)
}

public enum AppStorageStartupStatus: Equatable {
  case shared
  case legacy
  case recovery
}

extension AppStorageStartupSelection {
  public var allowsServerChanges: Bool {
    switch self {
    case .useShared, .useLegacy: return true
    case .unavailable: return false
    }
  }

  public var status: AppStorageStartupStatus {
    switch self {
    case .useShared: return .shared
    case .useLegacy: return .legacy
    case .unavailable: return .recovery
    }
  }
}

public enum AppStorageStartupError: Error, Equatable, LocalizedError {
  case completedStoreMarkerMissing
  case migrationDidNotComplete

  public var errorDescription: String? {
    switch self {
    case .completedStoreMarkerMissing:
      return "Shared storage was activated on an earlier launch but reports no completion marker."
    case .migrationDidNotComplete:
      return "Migration finished without a verified completion marker."
    }
  }
}

/// Chooses a storage mode for the current launch.
@MainActor
public enum AppStorageStartup {
  /// Zero permits a first import. Verified shared storage can repair unreadable activation history.
  // All six callbacks are startup dependencies; none has a safe default.
  // swiftlint:disable:next function_parameter_count
  public static func select(
    readActivatedVersion: () throws -> Int,
    validateLegacySource: () throws -> Void,
    resolve: () throws -> UserDefaults,
    readReadiness: (UserDefaults) throws -> SharedStorageReadiness,
    migrate: (UserDefaults) throws -> Void,
    markActivated: () throws -> Void
  ) -> AppStorageStartupSelection {
    let activation = Result(catching: readActivatedVersion)

    let suite: UserDefaults
    do {
      suite = try resolve()
    } catch {
      guard !hasPriorCutover(activation) else { return .unavailable(cause: error) }
      return legacyFallback(cause: error, validateLegacySource: validateLegacySource)
    }

    let readiness: SharedStorageReadiness
    do {
      readiness = try readReadiness(suite)
    } catch {
      return .unavailable(cause: error)
    }

    switch readiness {
    case .ready:
      return useReadyShared(suite, activation: activation, markActivated: markActivated)
    case .pending:
      switch activation {
      case .success(0):
        return attemptCutover(
          suite: suite,
          validateLegacySource: validateLegacySource,
          readReadiness: readReadiness,
          migrate: migrate,
          markActivated: markActivated
        )
      case .success:
        return .unavailable(cause: AppStorageStartupError.completedStoreMarkerMissing)
      case .failure(let error):
        return .unavailable(cause: error)
      }
    }
  }

  /// Unreadable history blocks legacy import.
  private static func hasPriorCutover(_ activation: Result<Int, any Error>) -> Bool {
    switch activation {
    case .success(let version): return version > 0
    case .failure: return true
    }
  }

  private static func useReadyShared(
    _ suite: UserDefaults,
    activation: Result<Int, any Error>,
    markActivated: () throws -> Void
  ) -> AppStorageStartupSelection {
    switch activation {
    case .success(let version) where version > 0:
      return .useShared(suite, didActivate: false)
    case .success, .failure:
      return activateShared(suite, markActivated: markActivated)
    }
  }

  private static func attemptCutover(
    suite: UserDefaults,
    validateLegacySource: () throws -> Void,
    readReadiness: (UserDefaults) throws -> SharedStorageReadiness,
    migrate: (UserDefaults) throws -> Void,
    markActivated: () throws -> Void
  ) -> AppStorageStartupSelection {
    var migrationCause: (any Error)?
    do {
      try migrate(suite)
    } catch {
      migrationCause = error
    }

    // Verified completion takes precedence over an import error.
    do {
      guard try readReadiness(suite) == .ready else {
        return legacyFallback(
          cause: migrationCause ?? AppStorageStartupError.migrationDidNotComplete,
          validateLegacySource: validateLegacySource
        )
      }
    } catch {
      return .unavailable(cause: error)
    }

    return activateShared(suite, markActivated: markActivated)
  }

  /// Every writable fallback must preserve the complete persisted source list.
  private static func legacyFallback(
    cause: any Error,
    validateLegacySource: () throws -> Void
  ) -> AppStorageStartupSelection {
    do {
      try validateLegacySource()
      return .useLegacy(cause: cause)
    } catch {
      return .unavailable(cause: error)
    }
  }

  private static func activateShared(
    _ suite: UserDefaults,
    markActivated: () throws -> Void
  ) -> AppStorageStartupSelection {
    do {
      try markActivated()
    } catch {
      return .unavailable(cause: error)
    }
    return .useShared(suite, didActivate: true)
  }
}
