import Foundation

public enum BundleMetadataError: Error, Equatable, LocalizedError {
  case missingInfoValue(String)
  case invalidInfoValue(String)

  public var errorDescription: String? {
    switch self {
    case .missingInfoValue(let key):
      return "Missing bundle metadata value for \(key)."
    case .invalidInfoValue(let key):
      return "Invalid bundle metadata value for \(key)."
    }
  }
}

extension Bundle {
  private static let containingAppIdentifierInfoKey = "HoleberryContainingAppIdentifier"
  private static let sharedAppGroupIdentifierInfoKey = "HoleberryAppGroupIdentifier"
  private static let sharedKeychainAccessGroupInfoKey = "HoleberryKeychainAccessGroup"

  /// Stable identifier for the current app bundle, preserving the historical
  /// Holeberry fallback used by legacy Keychain access and OSLog.
  public static var appIdentifier: String {
    Bundle.main.bundleIdentifier ?? "me.pedrovieira.holeberry"
  }

  /// Returns the App Group identifier from this bundle's Info.plist.
  ///
  /// Rejects missing, blank, and unexpanded values, plus identifiers without
  /// the `group.` prefix. The prefix check does not verify that the App Group
  /// is registered with the system.
  public func sharedAppGroupIdentifier() throws -> String {
    let identifier = try requiredMetadataValue(forKey: Self.sharedAppGroupIdentifierInfoKey)
    guard identifier.hasPrefix("group.") else {
      throw BundleMetadataError.invalidInfoValue(Self.sharedAppGroupIdentifierInfoKey)
    }
    return identifier
  }

  /// Returns the validated shared Keychain access group from this bundle's
  /// Info.plist. Rejects missing, blank, and unexpanded values.
  public func sharedKeychainAccessGroup() throws -> String {
    try requiredMetadataValue(forKey: Self.sharedKeychainAccessGroupInfoKey)
  }

  /// Returns the app identifier for an app or its embedded plug-in.
  ///
  /// Reads the target's own `HoleberryContainingAppIdentifier` metadata and
  /// rejects missing, blank, and unexpanded values. Never inspects the host
  /// bundle and never substitutes another bundle's identifier: the app and its
  /// widget must derive the same shared Keychain service.
  static func containingAppIdentifier(startingAt bundle: Bundle = .main) throws -> String {
    try bundle.requiredMetadataValue(forKey: containingAppIdentifierInfoKey)
  }

  private func requiredMetadataValue(forKey key: String) throws -> String {
    guard let rawValue = infoDictionary?[key] as? String else {
      throw BundleMetadataError.missingInfoValue(key)
    }

    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      throw BundleMetadataError.missingInfoValue(key)
    }
    guard !value.contains("$(") && !value.contains("${") else {
      throw BundleMetadataError.invalidInfoValue(key)
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
