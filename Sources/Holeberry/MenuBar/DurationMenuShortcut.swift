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

extension NSMenuItem {
  /// Applies the shortcut; `nil` leaves the item untouched.
  func applyDurationShortcut(_ shortcut: DurationMenuShortcut?) {
    guard let shortcut else { return }
    keyEquivalent = shortcut.keyEquivalent
    keyEquivalentModifierMask = shortcut.modifierMask
  }
}

/// Gives shortcuts only to the duration submenu that is currently open;
/// closed siblings carry none, so the same keys never match two submenus.
final class DurationShortcutScoper: NSObject, NSMenuDelegate {
  private weak var openMenu: NSMenu?

  func menuWillOpen(_ menu: NSMenu) {
    if let openMenu, openMenu !== menu { clear(openMenu) }
    applyShortcuts(to: menu)
    openMenu = menu
  }

  func menuDidClose(_ menu: NSMenu) {
    clear(menu)
    if openMenu === menu { openMenu = nil }
  }

  /// Rows are built as [durations..., separator, no-timer row, custom row].
  private func applyShortcuts(to menu: NSMenu) {
    let rows = menu.items.filter { !$0.isSeparatorItem }
    guard rows.count >= 2 else { return }
    for (index, item) in rows.dropLast(2).enumerated() {
      item.applyDurationShortcut(DurationMenuShortcut.duration(at: index))
    }
    rows[rows.count - 2].applyDurationShortcut(.noTimer)
    rows[rows.count - 1].applyDurationShortcut(.custom)
  }

  private func clear(_ menu: NSMenu) {
    for item in menu.items { item.keyEquivalent = "" }
  }
}
