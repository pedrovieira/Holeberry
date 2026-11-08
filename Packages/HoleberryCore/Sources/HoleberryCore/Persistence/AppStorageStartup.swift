import Foundation

@MainActor
public enum AppStorageStartupSelection {
  case useLegacy
  case useShared(SharedAppStorage, didMigrate: Bool)
  case unavailable
}

/// Selects application storage by resolving the real shared store before any
/// migration or activation. A failed migration never activates the shared store.
@MainActor
public enum AppStorageStartup {
  public static func select(
    isActivated: Bool,
    resolve: () throws -> SharedAppStorage,
    migrate: (SharedAppStorage) throws -> Void,
    markActivated: () -> Void
  ) -> AppStorageStartupSelection {
    if isActivated {
      do {
        return .useShared(try resolve(), didMigrate: false)
      } catch {
        return .unavailable
      }
    }

    do {
      let storage = try resolve()
      do {
        try migrate(storage)
        markActivated()
        return .useShared(storage, didMigrate: true)
      } catch {
        return .useLegacy
      }
    } catch {
      return .useLegacy
    }
  }
}
