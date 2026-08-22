import Defaults
import Foundation

/// What the "Unblock Current Tab" global shortcut should do when it fires:
/// unblock for one of the user's configured duration entries, indefinitely,
/// or for a duration prompted when the shortcut fires.
///
/// Stored as a reference to an entry's id (not its seconds), so editing a
/// duration in the Durations tab keeps the selection valid and its displayed
/// label current. Entries are immutable, so a stable id always maps to the
/// same seconds value. "Indefinite" is not a duration in seconds and is not
/// an entry in `Defaults[.unblockDurations]`, so it is its own case.
public enum UnblockCurrentTabDurationSelection: Codable, Hashable, Sendable {
  /// Unblock without an expiry: the domain stays allowlisted until removed.
  case indefinite
  /// Unblock for the configured duration entry with this id.
  case entry(UUID)
  /// Prompt for a duration each time the shortcut fires.
  case custom

  /// Resolves the selection against the live duration entries.
  ///
  /// - Returns: The entry's seconds for a finite unblock, or `nil` when the
  ///   selection is `.indefinite`, is `.custom` (the duration is chosen when
  ///   the shortcut fires), or references an entry that no longer exists
  ///   (deleted in the Durations tab after being selected here).
  public func resolve(durations: [UnblockDurationEntry]) -> TimeInterval? {
    switch self {
    case .indefinite, .custom:
      return nil
    case .entry(let id):
      return durations.first { $0.id == id }?.seconds
    }
  }

  /// Returns the selection with any dangling entry reference repaired to
  /// `.indefinite`, so the settings picker always displays the value the
  /// shortcut will actually use.
  public func healed(durations: [UnblockDurationEntry]) -> UnblockCurrentTabDurationSelection {
    switch self {
    case .indefinite, .custom:
      return self
    case .entry(let id):
      return durations.contains { $0.id == id } ? self : .indefinite
    }
  }
}

extension UnblockCurrentTabDurationSelection: Defaults.Serializable {}
