import Foundation

/// Resolves the App Group store and shared credential store from this bundle.
@MainActor
public struct BundleSharedStorage: SharedStorageProviding {
  private let interactive: Bool

  public init(interactive: Bool = true) {
    self.interactive = interactive
  }

  public func location() throws -> SharedStorageLocation {
    let identifier = try Bundle.main.sharedAppGroupIdentifier()
    return SharedStorageLocation(
      suite: try UserDefaults.sharedStorageSuite(appGroupIdentifier: identifier),
      suiteName: identifier
    )
  }

  public func keychain() throws -> any KeychainManaging {
    try KeychainManager.shared(
      accessGroup: Bundle.main.sharedKeychainAccessGroup(),
      interactive: interactive
    )
  }
}
