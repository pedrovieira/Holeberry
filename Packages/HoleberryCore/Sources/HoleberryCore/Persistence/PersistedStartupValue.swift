import CoreFoundation
import Defaults
import Foundation

/// A raw saved value that cannot stand in for the typed value a strict
/// shared-store, startup, or migration decision needs.
enum DefaultsValueValidationError: Error, Equatable {
  case malformedValue(String)
}

/// Strict reads for shared-store, startup, and migration decisions only.
///
/// Values come from one persistent domain, so registered defaults and the
/// argument domain cannot stand in for saved data. Ordinary storage reads and
/// writes must not opt into them; they use the typed keys in `DefaultsKeys.swift`.
enum PersistedStartupValue {
  /// One captured persistent domain, with no key or value knowledge.
  ///
  /// A decision that reads the domain more than once can combine values from two
  /// different writes: a marker from one state with a list from another. Capture
  /// the dictionary once, then decode every value from that same snapshot.
  struct Snapshot {
    private let values: [String: Any]

    init(suite: UserDefaults, suiteName: String) {
      values = suite.persistentDomain(forName: suiteName) ?? [:]
    }

    /// The saved value for a key name, or nil when the domain has no such key.
    func rawValue(forKey keyName: String) -> Any? {
      values[keyName]
    }
  }

  /// Missing means nothing was saved. A partially decoded list or a repeated identifier is invalid.
  static func servers(
    _ key: Defaults.Key<[ServerConfig]>,
    in snapshot: Snapshot
  ) throws -> [ServerConfig]? {
    guard let rawValue = snapshot.rawValue(forKey: key.name) else { return nil }
    guard
      let serialized = rawValue as? [ServerConfig.Serializable],
      let servers = [ServerConfig].bridge.deserialize(serialized),
      servers.count == serialized.count,
      Set(servers.map(\.id)).count == servers.count
    else {
      throw DefaultsValueValidationError.malformedValue(key.name)
    }
    return servers
  }

  /// Missing means no recorded version. A Boolean or floating-point number cannot
  /// become a version: accepting one could falsely report a completed migration,
  /// and treating corruption as zero could allow another import of stale legacy data.
  static func version(_ key: Defaults.Key<Int>, in snapshot: Snapshot) throws -> Int? {
    guard let rawValue = snapshot.rawValue(forKey: key.name) else { return nil }
    guard
      let number = rawValue as? NSNumber,
      CFGetTypeID(number) == CFNumberGetTypeID(),
      !CFNumberIsFloatType(number)
    else {
      throw DefaultsValueValidationError.malformedValue(key.name)
    }
    let value = number.intValue
    guard number.doubleValue == Double(value) else {
      throw DefaultsValueValidationError.malformedValue(key.name)
    }
    return value
  }

  /// Captures one domain and decodes the saved list from that snapshot.
  static func servers(in suite: UserDefaults, suiteName: String) throws -> [ServerConfig]? {
    try servers(
      Defaults.Keys.servers(suite: suite),
      in: Snapshot(suite: suite, suiteName: suiteName)
    )
  }

  /// Captures one domain and decodes the recorded version from that snapshot.
  static func version(_ key: Defaults.Key<Int>, suiteName: String) throws -> Int? {
    try version(key, in: Snapshot(suite: key.suite, suiteName: suiteName))
  }
}
