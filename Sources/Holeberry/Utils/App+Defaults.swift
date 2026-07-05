import Defaults
import Foundation

// MARK: - Defaults Keys
//
// All persistent storage keys in one place. Usage:
//   Defaults[.servers]            // get/set [ServerConfig]
//   Defaults[.recentBlockedCount] // get/set Int
//   @Default(.launchAtLogin) var launchAtLogin: Bool
//
// These replace all direct UserDefaults access and @AppStorage usage.
// Defaults handles Codable types automatically.

extension Defaults.Keys {
  /// List of configured Pi-hole instances.
  static let servers = Defaults.Key<[ServerConfig]>("servers", default: [])

  /// How many recent blocked queries to fetch (persisted slider value).
  static let recentBlockedCount = Defaults.Key<Int>("recentBlockedCount", default: 20)

  /// Whether the app should launch at login.
  static let launchAtLogin = Defaults.Key<Bool>("launchAtLogin", default: false)

  /// Whether browser tab URL unblocking is enabled (off by default).
  static let browserTabUnblockEnabled = Defaults.Key<Bool>("browserTabUnblockEnabled", default: false)

  /// Returns a per-server key for temp-unblock records.
  static func tempUnblocks(for serverID: UUID) -> Defaults.Key<[TempUnblockRecord]> {
    Defaults.Key<[TempUnblockRecord]>("tempUnblocks-\(serverID.uuidString)", default: [])
  }
}
