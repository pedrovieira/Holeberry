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

  /// Single source of truth for "when should this next fire." Persisting the
  /// computed due date (rather than `lastRun` + recomputed interval) means
  /// "is it due" is always a one-line comparison.
  public static func gravityUpdateNextDue(
    suite: UserDefaults = .standard
  ) -> Defaults.Key<Date?> {
    Defaults.Key<Date?>("gravityUpdateNextDue", default: nil, suite: suite)
  }
}
