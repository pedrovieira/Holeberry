import Defaults
import Foundation

// MARK: - Defaults Keys
//
// All persistent storage keys in one place. Usage:
//   Defaults[.servers()]              // get/set [ServerConfig]
//   Defaults[.servers(suite:)]        // with custom suite
//   Defaults[.recentBlockedCount()]   // get/set Int
//   @Default(.launchAtLogin()) var launchAtLogin: Bool
//
// These replace all direct UserDefaults access and @AppStorage usage.
// Defaults handles Codable types automatically.

extension Defaults.Keys {
  /// List of configured Pi-hole instances.
  static func servers(suite: UserDefaults = .standard) -> Defaults.Key<[ServerConfig]> {
    Defaults.Key<[ServerConfig]>("servers", default: [], suite: suite)
  }

  /// How many recent blocked queries to fetch (persisted slider value).
  static func recentBlockedCount(suite: UserDefaults = .standard) -> Defaults.Key<Int> {
    Defaults.Key<Int>("recentBlockedCount", default: 20, suite: suite)
  }

  /// Whether the app should launch at login.
  static func launchAtLogin(suite: UserDefaults = .standard) -> Defaults.Key<Bool> {
    Defaults.Key<Bool>("launchAtLogin", default: false, suite: suite)
  }

  /// Whether browser tab URL unblocking is enabled (off by default).
  static func browserTabUnblockEnabled(suite: UserDefaults = .standard) -> Defaults.Key<Bool> {
    Defaults.Key<Bool>("browserTabUnblockEnabled", default: false, suite: suite)
  }

  /// Whether to show recently blocked domains for all network clients (off by default).
  static func showAllClientsRecentBlocked(suite: UserDefaults = .standard) -> Defaults.Key<Bool> {
    Defaults.Key<Bool>("showAllClientsRecentBlocked", default: false, suite: suite)
  }

  /// Returns a per-server key for temp-unblock records.
  static func tempUnblocks(for serverID: UUID, suite: UserDefaults = .standard) -> Defaults.Key<[TempUnblockRecord]> {
    Defaults.Key<[TempUnblockRecord]>("tempUnblocks-\(serverID.uuidString)", default: [], suite: suite)
  }
}
