import AppKit

/// A submenu for recently-blocked domains that rebuilds its items from scratch
/// each time it opens (via `menuNeedsUpdate`/`menuWillOpen`), so relative
/// timestamps are always fresh.
///
/// The duration submenus for each domain are provided by a closure so the
/// caller (MenuBuilder) supplies fully-wired menus whose items already target
/// the shared `MenuActionTarget` — no `@objc` or duplicating that logic here.
final class RecentlyBlockedMenu: NSMenu, NSMenuDelegate {
  private let fetchBlocked: () -> [BlockedDomain]
  private let userIP: String?
  private let showAllClients: Bool
  private let buildDurationSubmenu: (String) -> NSMenu

  init(
    fetchBlocked: @escaping () -> [BlockedDomain],
    userIP: String?,
    showAllClients: Bool,
    buildDurationSubmenu: @escaping (String) -> NSMenu
  ) {
    self.fetchBlocked = fetchBlocked
    self.userIP = userIP
    self.showAllClients = showAllClients
    self.buildDurationSubmenu = buildDurationSubmenu
    super.init(title: "")
    self.delegate = self
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - NSMenuDelegate

  func menuWillOpen(_ menu: NSMenu) {
    menuNeedsUpdate(menu)
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    let blockedDomains = fetchBlocked()

    guard !blockedDomains.isEmpty else {
      let item = NSMenuItem(title: "No recently blocked domains", action: nil, keyEquivalent: "")
      item.isEnabled = false
      addItem(item)
      return
    }

    for entry in blockedDomains {
      let domainItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
      domainItem.attributedTitle = Self.attributedTitle(for: entry)
      domainItem.submenu = buildDurationSubmenu(entry.domain)

      if showAllClients, entry.fromClientIp == userIP {
        domainItem.image = .init(systemSymbolName: "person.circle", accessibilityDescription: "")
      }

      addItem(domainItem)
    }
  }

  // MARK: - Attributed title

  /// Builds a two-line attributed title: domain name + relative timestamp and hit count below.
  static func attributedTitle(for entry: BlockedDomain) -> NSAttributedString {
    let result = NSMutableAttributedString()

    let domainAttr: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
      .foregroundColor: NSColor.labelColor
    ]
    result.append(NSAttributedString(string: entry.domain, attributes: domainAttr))

    let timestamp = MenuItemFactory.relativeTimestamp(since: entry.timestamp)
    let hitSuffix = entry.count == 1 ? "1 hit" : "\(entry.count) hits"
    let timeAttr: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
      .foregroundColor: NSColor.secondaryLabelColor
    ]

    let subtitle = NSAttributedString(string: timestamp + " · " + hitSuffix, attributes: timeAttr)

    result.append(NSAttributedString(string: "\n"))
    result.append(subtitle)

    return result
  }
}
