import AppKit
import HoleberryCore

/// Key equivalent for one row of a duration submenu: ⌘1…⌘9 top to bottom,
/// ⌘0 for the tenth, none past that. `.noTimer` covers both "Indefinitely"
/// and "Add to allowlist".
enum DurationMenuShortcut {
  case durationDigit(Character)
  case noTimer
  case custom

  /// The tenth row is "0". Keep this at least as long as `UnblockDurationEntry.maxCount`.
  private static let durationDigits = Array("1234567890")

  /// The shortcut for the duration at zero-based `index`, or `nil` past the tenth row.
  static func duration(at index: Int) -> Self? {
    durationDigits.indices.contains(index) ? .durationDigit(durationDigits[index]) : nil
  }

  var keyEquivalent: String {
    switch self {
    case .durationDigit(let digit): String(digit)
    case .noTimer: "a"
    case .custom: "c"
    }
  }

  var modifierMask: NSEvent.ModifierFlags {
    switch self {
    case .durationDigit: .command
    case .noTimer, .custom: [.command, .shift]
    }
  }

  /// As macOS renders it in a menu (⌃⌥⇧⌘ order).
  var displayString: String {
    switch self {
    case .durationDigit(let digit): "⌘\(digit)"
    case .noTimer: "⇧⌘A"
    case .custom: "⇧⌘C"
    }
  }
}
