import Defaults
import Foundation

// MARK: - Defaults Keys
//
// All persistent storage keys in one place. Usage:
//   Defaults[.servers]            // get/set [PiholeServer]
//   Defaults[.recentBlockedCount] // get/set Int
//   @Default(.launchAtLogin) var launchAtLogin: Bool
//
// These replace all direct UserDefaults access and @AppStorage usage.
// Defaults handles Codable types automatically.

extension Defaults.Keys {
  /// JSON-encoded list of configured Pi-hole instances.
  static let servers = Defaults.Key<[PiholeServer]>("servers", default: [])

  /// How many recent blocked queries to fetch (persisted slider value).
  static let recentBlockedCount = Defaults.Key<Int>("recentBlockedCount", default: 20)

  /// Whether the app should launch at login.
  static let launchAtLogin = Defaults.Key<Bool>("launchAtLogin", default: false)

  /// JSON-encoded list of active temp-unblock records.
  static let tempUnblocks = Defaults.Key<[TempUnblockRecord]>(
    "tempUnblocks", default: [])
}
