import CoreFoundation
import Defaults
import Foundation

/// A saved value that fails strict decoding.
enum DefaultsValueValidationError: Error, Equatable {
  case malformedValue(String)
}

/// Strict persisted-value decoding for shared storage, startup, and migration.
/// Ordinary access uses typed keys in `DefaultsKeys.swift`.
enum PersistedStartupValue {
  /// One domain snapshot keeps related reads consistent during concurrent writes.
  struct Snapshot {
    private let values: [String: Any]

    init(domain: [String: Any]) {
      values = domain
    }

    /// Saved value, or nil if absent.
    func rawValue(forKey keyName: String) -> Any? {
      values[keyName]
    }
  }

  /// Absent lists return nil; partial decoding or duplicate IDs throw.
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

  /// Missing returns nil; Booleans and floats throw to prevent false completion.
  /// Corruption must not become zero and replay legacy data.
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

  /// Decodes the saved list from one snapshot.
  static func servers(in suite: UserDefaults, suiteName: String) throws -> [ServerConfig]? {
    try servers(
      Defaults.Keys.servers(suite: suite),
      in: Snapshot(domain: suite.capturedPersistentDomain(named: suiteName))
    )
  }

  /// Decodes the saved version from one snapshot.
  static func version(_ key: Defaults.Key<Int>, suiteName: String) throws -> Int? {
    try version(key, in: Snapshot(domain: key.suite.capturedPersistentDomain(named: suiteName)))
  }
}
