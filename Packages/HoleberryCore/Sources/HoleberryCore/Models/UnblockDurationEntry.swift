import Defaults
import Foundation

/// A single numeric unblock duration shown in the duration menus.
///
/// Only numeric durations are stored; "Indefinitely" and "Custom…" are
/// structural rows rendered by the menu builder and settings preview.
public struct UnblockDurationEntry: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let seconds: TimeInterval

  public init(id: UUID = UUID(), seconds: TimeInterval) {
    self.id = id
    self.seconds = seconds
  }

  /// Upper bound on stored durations, to keep menus from growing unwieldy.
  public static let maxCount = 10

  /// Stable ids for the default entries. These are literals so that
  /// persisted lists keep mapping to the legacy shortcut names
  /// (`disable10s` / `disable30s` / `disable5m`) across launches.
  public static let default10sID = UUID.stable("00000000-0000-4000-8000-00000000000A")
  public static let default30sID = UUID.stable("00000000-0000-4000-8000-00000000001E")
  public static let default5mID = UUID.stable("00000000-0000-4000-8000-00000000012C")

  /// The default menu list: 10 seconds, 30 seconds, 5 minutes, in order.
  public static let defaultEntries: [UnblockDurationEntry] = [
    UnblockDurationEntry(id: default10sID, seconds: 10),
    UnblockDurationEntry(id: default30sID, seconds: 30),
    UnblockDurationEntry(id: default5mID, seconds: 300)
  ]
}

extension UUID {
  /// Parses a fixed literal. `preconditionFailure` fires only if a
  /// programmer-supplied literal is malformed — never at runtime for users.
  static func stable(_ string: String) -> UUID {
    guard let uuid = UUID(uuidString: string) else {
      preconditionFailure("Invalid stable UUID literal: \(string)")
    }
    return uuid
  }
}

extension UnblockDurationEntry: Defaults.Serializable {}
