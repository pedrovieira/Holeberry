import CoreFoundation
import Defaults
import Foundation

// MARK: - Defaults Keys
//
// All persistent storage keys in one place. Usage:
//   Defaults[.servers()]              // get/set [ServerConfig]
//   Defaults[.servers(suite:)]        // with custom suite
//   @Default(.launchAtLogin()) var launchAtLogin: Bool
//
// These replace all direct UserDefaults access and @AppStorage usage.
// Defaults handles Codable types automatically.

extension Defaults.Keys {
  /// List of configured Pi-hole instances.
  public static func servers(suite: UserDefaults = .standard) -> Defaults.Key<[ServerConfig]> {
    Defaults.Key<[ServerConfig]>("servers", default: [], suite: suite)
  }

  /// Whether the app should launch at login.
  public static func launchAtLogin(suite: UserDefaults = .standard) -> Defaults.Key<Bool> {
    Defaults.Key<Bool>("launchAtLogin", default: false, suite: suite)
  }

  /// Whether browser tab URL unblocking is enabled (off by default).
  public static func browserTabUnblockEnabled(suite: UserDefaults = .standard) -> Defaults.Key<Bool> {
    Defaults.Key<Bool>("browserTabUnblockEnabled", default: false, suite: suite)
  }

  /// Whether to show recently blocked domains for all network clients (off by default).
  public static func showAllClientsRecentBlocked(suite: UserDefaults = .standard) -> Defaults.Key<Bool> {
    Defaults.Key<Bool>("showAllClientsRecentBlocked", default: false, suite: suite)
  }

  /// Whether the main menu shows each instance's queries/blocked stats subtitle
  /// (on by default). Only visible when 2 instances are connected.
  public static func showPerInstanceStats(suite: UserDefaults = .standard) -> Defaults.Key<Bool> {
    Defaults.Key<Bool>("showPerInstanceStats", default: true, suite: suite)
  }

  /// Whether the main menu shows the Gravity update item (on by default).
  public static func showGravityMenuItem(suite: UserDefaults = .standard) -> Defaults.Key<Bool> {
    Defaults.Key<Bool>("showGravityMenuItem", default: true, suite: suite)
  }

  /// Whether to notify when a temporary unblock ends on its own (on by default).
  /// Never fires when the user re-enables blocking manually.
  public static func notifyWhenUnblockEnds(suite: UserDefaults = .standard) -> Defaults.Key<Bool> {
    Defaults.Key<Bool>("notifyWhenUnblockEnds", default: true, suite: suite)
  }

  /// Whether to notify when a temporary unblock for a specific domain ends on
  /// its own (on by default). Applies to domain unblocks from the Recently
  /// Blocked menu and the browser tab.
  public static func notifyWhenDomainUnblockEnds(suite: UserDefaults = .standard) -> Defaults.Key<Bool> {
    Defaults.Key<Bool>("notifyWhenDomainUnblockEnds", default: true, suite: suite)
  }

  /// Whether to notify when an in-app gravity update completes (on by default).
  /// Failure notifications are always shown.
  public static func notifyGravityUpdateCompleted(suite: UserDefaults = .standard) -> Defaults.Key<Bool> {
    Defaults.Key<Bool>("notifyGravityUpdateCompleted", default: true, suite: suite)
  }

  /// Ordered list of numeric unblock durations shown in the duration menus.
  public static func unblockDurations(
    suite: UserDefaults = .standard
  ) -> Defaults.Key<[UnblockDurationEntry]> {
    Defaults.Key<[UnblockDurationEntry]>(
      "unblockDurations",
      default: UnblockDurationEntry.defaultEntries,
      suite: suite
    )
  }

  /// What the "Unblock Current Tab" global shortcut should do when it fires.
  /// Defaults to the stable 5-minute entry; resolves to indefinite if that
  /// entry is ever removed from the durations list.
  public static func unblockCurrentTabDuration(
    suite: UserDefaults = .standard
  ) -> Defaults.Key<UnblockCurrentTabDurationSelection> {
    Defaults.Key<UnblockCurrentTabDurationSelection>(
      "unblockCurrentTabDuration",
      default: .entry(UnblockDurationEntry.default5mID),
      suite: suite
    )
  }

  /// Returns a per-server key for temp-unblock records.
  public static func tempUnblocks(
    for serverID: UUID, suite: UserDefaults = .standard
  ) -> Defaults.Key<[TempUnblockRecord]> {
    Defaults.Key<[TempUnblockRecord]>("tempUnblocks-\(serverID.uuidString)", default: [], suite: suite)
  }

  /// The cadence for automatic gravity updates (off by default: `.never`).
  public static func gravityUpdateCadence(
    suite: UserDefaults = .standard
  ) -> Defaults.Key<GravityUpdateCadence> {
    Defaults.Key<GravityUpdateCadence>("gravityUpdateCadence", default: .never, suite: suite)
  }

  /// When the next automatic gravity update is due; nil = not scheduled.
  public static func gravityUpdateNextDue(
    suite: UserDefaults = .standard
  ) -> Defaults.Key<Date?> {
    Defaults.Key<Date?>("gravityUpdateNextDue", default: nil, suite: suite)
  }

  /// Verified App Group migration version. Zero means pending.
  public static func sharedStorageMigrationVersion(
    suite: UserDefaults = .standard
  ) -> Defaults.Key<Int> {
    Defaults.Key<Int>("sharedStorageMigrationVersion", default: 0, suite: suite)
  }

  /// App-local record of prior shared storage activation.
  public static func sharedStorageActivatedVersion(
    suite: UserDefaults = .standard
  ) -> Defaults.Key<Int> {
    Defaults.Key<Int>("sharedStorageActivatedVersion", default: 0, suite: suite)
  }
}

public enum DefaultsSuiteError: Error, Equatable {
  case unavailableGroupSuite(String)
}

extension UserDefaults {
  /// Opens the registered App Group suite. Never falls back to `.standard`.
  public static func sharedStorageSuite(appGroupIdentifier: String) throws -> UserDefaults {
    guard let suite = UserDefaults(suiteName: appGroupIdentifier) else {
      throw DefaultsSuiteError.unavailableGroupSuite(appGroupIdentifier)
    }
    return suite
  }
}

enum DefaultsValueValidationError: Error, Equatable {
  case malformedValue(String)
  case missingPersistedValue(String)
}

// Strict reads reject partial arrays and can bypass registered defaults.
extension Defaults.Keys {
  /// Requires an explicitly saved array. Readback checks the in-process domain.
  static func strictlyDecodedPersistedArray<Element: Defaults.Serializable>(
    _ key: Defaults.Key<[Element]>,
    suiteName: String
  ) throws -> [Element] {
    try PersistedDomain(suite: key.suite, name: suiteName).strictlyDecodedArray(key)
  }

  static func strictlyDecodedPersistedInt(
    _ key: Defaults.Key<Int>,
    suiteName: String
  ) throws -> Int? {
    try PersistedDomain(suite: key.suite, name: suiteName).strictlyDecodedInt(key)
  }

  struct PersistedDomain {
    private let values: [String: Any]

    init(suite: UserDefaults, name: String) {
      values = suite.persistentDomain(forName: name) ?? [:]
    }

    func strictlyDecodedArray<Element: Defaults.Serializable>(
      _ key: Defaults.Key<[Element]>
    ) throws -> [Element] {
      guard let rawValue = values[key.name] else {
        throw DefaultsValueValidationError.missingPersistedValue(key.name)
      }
      return try Defaults.Keys.decodeStrictArray(rawValue, keyName: key.name)
    }

    /// Missing means a fresh install. A partially decoded list or repeated ID is invalid.
    func servers(in suite: UserDefaults) throws -> [ServerConfig]? {
      let key = Defaults.Keys.servers(suite: suite)
      guard values[key.name] != nil else { return nil }
      let servers = try strictlyDecodedArray(key)
      guard Set(servers.map(\.id)).count == servers.count else {
        throw DefaultsValueValidationError.malformedValue(key.name)
      }
      return servers
    }

    /// Rejects Boolean or fractional values.
    func strictlyDecodedInt(_ key: Defaults.Key<Int>) throws -> Int? {
      guard let rawValue = values[key.name] else { return nil }
      guard let number = rawValue as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else {
        throw DefaultsValueValidationError.malformedValue(key.name)
      }
      let value = number.intValue
      guard number.doubleValue == Double(value) else {
        throw DefaultsValueValidationError.malformedValue(key.name)
      }
      return value
    }
  }

  private static func decodeStrictArray<Element: Defaults.Serializable>(
    _ rawValue: Any,
    keyName: String
  ) throws -> [Element] {
    guard let serializedElements = rawValue as? [Element.Serializable] else {
      throw DefaultsValueValidationError.malformedValue(keyName)
    }
    guard
      let decoded = [Element].bridge.deserialize(serializedElements),
      decoded.count == serializedElements.count
    else {
      throw DefaultsValueValidationError.malformedValue(keyName)
    }
    return decoded
  }
}

/// Empty, no-write suite used only when previously activated shared storage
/// cannot be reopened. It must never read, contain, or mutate data. Keeping the
/// adapter here makes every raw `UserDefaults` override live in this file.
public final class UnavailableDefaults: UserDefaults {
  @MainActor public static let shared = UnavailableDefaults()

  public override func object(forKey defaultName: String) -> Any? { nil }
  public override func set(_ value: Any?, forKey defaultName: String) {}
  public override func removeObject(forKey defaultName: String) {}
  public override func register(defaults registrationDictionary: [String: Any]) {}

  public override func persistentDomain(forName domainName: String) -> [String: Any]? { nil }
  public override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {}
  public override func removePersistentDomain(forName domainName: String) {}
  public override func dictionaryRepresentation() -> [String: Any] { [:] }

  public override var volatileDomainNames: [String] { [] }
  public override func volatileDomain(forName domainName: String) -> [String: Any] { [:] }
  public override func setVolatileDomain(_ domain: [String: Any], forName domainName: String) {}
  public override func removeVolatileDomain(forName domainName: String) {}
}
