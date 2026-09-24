import AppKit

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
      apply(DurationMenuShortcut.duration(at: index), to: item)
    }
    apply(.noTimer, to: rows[rows.count - 2])
    apply(.custom, to: rows[rows.count - 1])
  }

  private func apply(_ shortcut: DurationMenuShortcut?, to item: NSMenuItem) {
    guard let shortcut else { return }
    item.keyEquivalent = shortcut.keyEquivalent
    item.keyEquivalentModifierMask = shortcut.modifierMask
  }

  private func clear(_ menu: NSMenu) {
    for item in menu.items { item.keyEquivalent = "" }
  }
}
