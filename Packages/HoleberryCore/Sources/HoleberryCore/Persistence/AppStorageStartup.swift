import Foundation

@MainActor
public enum AppStorageStartupSelection {
  case useShared(UserDefaults, didMigrate: Bool)
  case unavailable
}

/// Resolves and activates the shared App Group suite before the application
/// manager is constructed.
///
/// There is no legacy fallback: a suite that cannot be resolved or migrated is
/// reported as unavailable, and the app runs with no-write empty stores.
@MainActor
public enum AppStorageStartup {
  public static func select(
    isActivated: Bool,
    resolve: () throws -> UserDefaults,
    migrate: (UserDefaults) throws -> Void,
    markActivated: () -> Void
  ) -> AppStorageStartupSelection {
    do {
      let suite = try resolve()
      guard !isActivated else {
        return .useShared(suite, didMigrate: false)
      }

      try migrate(suite)
      markActivated()
      return .useShared(suite, didMigrate: true)
    } catch {
      return .unavailable
    }
  }
}
