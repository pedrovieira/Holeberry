import Foundation

/// Resolves the App Group store and shared credential store from a bundle.
///
/// Bundle metadata and the credential store location are stable for a process, so
/// each instance resolves them once. The app and the widget hold one instance each,
/// because only the app may show a credential prompt.
@MainActor
public final class BundleSharedStorage: SharedStorageProviding {
  /// The app's store. Credential access may prompt.
  public static let app = BundleSharedStorage(interactive: true)
  /// The widget's store. Credential access never prompts.
  public static let widget = BundleSharedStorage(interactive: false)

  private let interactive: Bool
  private let bundle: Bundle
  /// Successful resolutions only: a transient failure must stay retryable on the
  /// next `start()`.
  private var resolvedLocation: SharedStorageLocation?
  private var resolvedKeychain: (any KeychainManaging)?

  public init(interactive: Bool, bundle: Bundle = .main) {
    self.interactive = interactive
    self.bundle = bundle
  }

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
