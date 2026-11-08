import Foundation

public enum SharedAppStorageError: Error, Equatable {
  case missingInfoValue(String)
  case invalidInfoValue(String)
  case unavailableAppGroupContainer(String)
  case unavailableGroupSuite(String)
}

/// Bundle-provided identifiers for the App Group and shared Keychain group.
public struct SharedAppStorageConfiguration: Equatable, Sendable {
  public let appGroupIdentifier: String
  public let keychainAccessGroup: String

  public init(appGroupIdentifier: String, keychainAccessGroup: String) {
    self.appGroupIdentifier = appGroupIdentifier
    self.keychainAccessGroup = keychainAccessGroup
  }

  public init(bundle: Bundle = .main) throws {
    guard let infoDictionary = bundle.infoDictionary else {
      throw SharedAppStorageError.missingInfoValue(SharedAppStorage.appGroupIdentifierInfoKey)
    }
    try self.init(infoDictionary: infoDictionary)
  }

  public init(infoDictionary: [String: Any]) throws {
    let appGroupIdentifier = try Self.requiredValue(
      forKey: SharedAppStorage.appGroupIdentifierInfoKey,
      in: infoDictionary
    )
    guard appGroupIdentifier.hasPrefix("group.") else {
      throw SharedAppStorageError.invalidInfoValue(SharedAppStorage.appGroupIdentifierInfoKey)
    }

    self.init(
      appGroupIdentifier: appGroupIdentifier,
      keychainAccessGroup: try Self.requiredValue(
        forKey: SharedAppStorage.keychainAccessGroupInfoKey,
        in: infoDictionary
      )
    )
  }

  private static func requiredValue(forKey key: String, in infoDictionary: [String: Any]) throws -> String {
    guard let rawValue = infoDictionary[key] as? String else {
      throw SharedAppStorageError.missingInfoValue(key)
    }

    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      throw SharedAppStorageError.missingInfoValue(key)
    }
    guard !value.contains("$(") else {
      throw SharedAppStorageError.invalidInfoValue(key)
    }
    return value
  }
}

/// Resolves the registered App Group suite/container and shared Keychain group.
///
/// Resolution throws instead of falling back to the standard defaults suite or
/// an ungrouped Keychain when configuration or group storage is unavailable.
public struct SharedAppStorage {
  public static let registeredAppGroupIdentifier = "group.me.pedrovieira.holeberry"
  public static let appGroupIdentifierInfoKey = "HoleberryAppGroupIdentifier"
  public static let keychainAccessGroupInfoKey = "HoleberryKeychainAccessGroup"

  public let configuration: SharedAppStorageConfiguration
  public let suite: UserDefaults
  public let containerURL: URL

  public init(bundle: Bundle = .main, fileManager: FileManager = .default) throws {
    let configuration = try SharedAppStorageConfiguration(bundle: bundle)
    guard
      let containerURL = fileManager.containerURL(
        forSecurityApplicationGroupIdentifier: configuration.appGroupIdentifier
      )
    else {
      throw SharedAppStorageError.unavailableAppGroupContainer(configuration.appGroupIdentifier)
    }

    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: containerURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw SharedAppStorageError.unavailableAppGroupContainer(configuration.appGroupIdentifier)
    }
    guard let suite = UserDefaults(suiteName: configuration.appGroupIdentifier) else {
      throw SharedAppStorageError.unavailableGroupSuite(configuration.appGroupIdentifier)
    }

    self.init(configuration: configuration, suite: suite, containerURL: containerURL)
  }

  init(configuration: SharedAppStorageConfiguration, suite: UserDefaults, containerURL: URL) {
    self.configuration = configuration
    self.suite = suite
    self.containerURL = containerURL
  }
}
