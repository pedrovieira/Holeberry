import Foundation

@MainActor
public enum AppStorageStartupSelection {
  case useShared(UserDefaults, didMigrate: Bool)
  /// The shared suite could not be resolved or migrated. `cause` is the error
  /// that ended startup, kept so the caller can log it.
  case unavailable(cause: any Error)
}

/// Resolves and activates the shared App Group suite before the application
/// manager is constructed.
///
/// There is no legacy fallback: a suite that cannot be resolved or migrated is
/// reported as unavailable, and the app runs with no-write empty stores.
@MainActor
public enum AppStorageStartup {
  /// Resolves the shared suite and migrates it unless the current migration
  /// generation was already activated.
  ///
  /// - Parameter isCurrentMigrationActivated: `true` when the standard suite
  ///   already recorded `SharedStorageMigration.currentVersion`; a newer
  ///   generation deliberately returns `false` so migration runs again.
  public static func select(
    isCurrentMigrationActivated: Bool,
    resolve: () throws -> UserDefaults,
    migrate: (UserDefaults) throws -> Void,
    markActivated: () -> Void
  ) -> AppStorageStartupSelection {
    do {
      let suite = try resolve()
      guard !isCurrentMigrationActivated else {
        return .useShared(suite, didMigrate: false)
      }

      try migrate(suite)
      markActivated()
      return .useShared(suite, didMigrate: true)
    } catch {
      return .unavailable(cause: error)
    }
  }
}
