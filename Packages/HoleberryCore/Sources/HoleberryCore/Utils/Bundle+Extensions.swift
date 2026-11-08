import Foundation

extension Bundle {
  private static let containingAppIdentifierInfoKey = "HoleberryContainingAppIdentifier"

  /// Stable identifier for the current app bundle, preserving the historical
  /// Holeberry fallback used by legacy Keychain access and OSLog.
  public static var appIdentifier: String {
    Bundle.main.bundleIdentifier ?? "me.pedrovieira.holeberry"
  }

  /// Returns the app identifier for an app or its embedded plug-in.
  ///
  /// Reads the target's own `HoleberryContainingAppIdentifier` metadata; an
  /// absent, empty, or unexpanded value falls back to `appIdentifier`. Never
  /// inspects the host bundle.
  static func containingAppIdentifier(startingAt bundle: Bundle = .main) -> String {
    guard
      let rawValue = bundle.infoDictionary?[containingAppIdentifierInfoKey] as? String
    else {
      return appIdentifier
    }

    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !value.contains("$(") else {
      return appIdentifier
    }
    return value
  }

  public var releaseVersionNumber: String? {
    infoDictionary?["CFBundleShortVersionString"] as? String
  }

  public var buildVersionNumber: String? {
    infoDictionary?["CFBundleVersion"] as? String
  }
}
