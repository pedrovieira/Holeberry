import Foundation

/// Resolves the App Group store and the shared credential store from a bundle.
///
/// Bundle metadata and the credential store location are stable for a process,
/// so each instance resolves them once. The app and the widget hold one instance
/// each, because only the app may show a credential prompt.
///
/// Only successful resolutions are cached. A transient failure stays retryable
/// on the next call and is never remembered as a value.
@MainActor
public final class BundleSharedStorage: SharedStorageProviding {
  /// The app's store. Credential access may prompt.
  public static let app = BundleSharedStorage(interactive: true)
  /// The widget's store. Credential access never prompts.
  public static let widget = BundleSharedStorage(interactive: false)

  private let interactive: Bool
  private let bundle: Bundle
  private var resolvedLocation: SharedStorageLocation?
  private var resolvedKeychain: (any KeychainManaging)?

  /// - Parameters:
  ///   - interactive: Whether credential access may show a prompt. `false` in
  ///     every widget process.
  ///   - bundle: Source of the App Group and Keychain access-group metadata.
  ///     Tests inject a fixture bundle; production uses the process bundle.
  public init(interactive: Bool, bundle: Bundle = .main) {
    self.interactive = interactive
    self.bundle = bundle
  }

  /// Resolves the App Group suite. Invalid, missing, or unexpanded metadata
  /// throws rather than falling back to another store.
  public func location() throws -> SharedStorageLocation {
    if let resolvedLocation { return resolvedLocation }
    let identifier = try bundle.sharedAppGroupIdentifier()
    let location = SharedStorageLocation(
      suite: try UserDefaults.sharedStorageSuite(appGroupIdentifier: identifier),
      suiteName: identifier
    )
    resolvedLocation = location
    return location
  }

  /// Resolves the shared credential store. Both processes derive the service
  /// from `HoleberryContainingAppIdentifier`, so they address the same items.
  public func keychain() throws -> any KeychainManaging {
    if let resolvedKeychain { return resolvedKeychain }
    let keychain = try KeychainManager.shared(
      accessGroup: bundle.sharedKeychainAccessGroup(),
      interactive: interactive,
      startingAt: bundle
    )
    resolvedKeychain = keychain
    return keychain
  }
}
