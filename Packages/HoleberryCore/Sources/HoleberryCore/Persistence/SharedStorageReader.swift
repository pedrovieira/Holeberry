import Foundation

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

/// Why the shared copy cannot serve a widget read yet.
public enum SharedStorageReaderError: Error, Equatable, LocalizedError {
  /// The app has not completed the copy into shared storage.
  case notReady

  public var errorDescription: String? {
    switch self {
    case .notReady:
      return "Shared storage is not ready yet."
    }
  }
}

/// Reads the completed App Group copy for the widget.
///
/// Holds no legacy, migration, or startup state: the app owns that copy, so the
/// widget validates it read-only and never migrates, activates, or repairs it.
/// Every call revalidates, because the app can rewrite the copy while a widget
/// load is suspended.
@MainActor
public struct SharedStorageReader {
  private let sharedStorage: any SharedStorageProviding
  private let appLocalSuite: UserDefaults

  /// - Parameter appLocalSuite: Backing store for temporary-unblock records.
  ///   Widgets never write these records.
  public init(
    sharedStorage: any SharedStorageProviding = BundleSharedStorage.widget,
    appLocalSuite: UserDefaults = .standard
  ) {
    self.sharedStorage = sharedStorage
    self.appLocalSuite = appLocalSuite
  }

  /// Reads the completed saved-server list without resolving credentials.
  ///
  /// Throws `SharedStorageReaderError.notReady` while the copy is pending and
  /// `SharedStorageReadinessError` when the completed copy is invalid.
  public func servers() throws -> [ServerConfig] {
    let location = try sharedStorage.location()
    guard
      let servers = try SharedStorageValidation.completedServers(
        in: location.suite,
        suiteName: location.suiteName
      )
    else {
      throw SharedStorageReaderError.notReady
    }
    return servers
  }

  /// Opens the completed shared store with its shared credentials.
  ///
  /// Requires readiness first, so an invalid or pending copy never opens the
  /// credential store.
  public func openStorage() throws -> any AppStorageProviding {
    let location = try sharedStorage.location()
    let readiness = try SharedStorageValidation.readiness(
      in: location.suite,
      suiteName: location.suiteName
    )
    guard readiness == .ready else {
      throw SharedStorageReaderError.notReady
    }
    return ConcreteAppStorage(
      sharedDataSuite: location.suite,
      appLocalSuite: appLocalSuite,
      keychain: try sharedStorage.keychain()
    )
  }
}
