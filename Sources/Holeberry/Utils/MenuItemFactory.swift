import AppKit

/// Stateless helpers that build `NSAttributedString` components for menu items.
enum MenuItemFactory {
  // MARK: - Dot

  /// An `NSTextAttachment` containing a tinted SF Symbol circle.
  /// - Parameters:
  ///   - color: The fill color applied to the circle.
  ///   - diameter: Point size of the symbol (default 8).
  static func dotAttachment(color: NSColor, diameter: CGFloat = 8) -> NSTextAttachment {
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: diameter, weight: .medium)
      .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))

    let image =
      NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(symbolConfig)
      ?? NSImage(size: NSSize(width: diameter, height: diameter))

    let attachment = NSTextAttachment()
    attachment.image = image

    // Center the dot vertically against the system font's cap height.
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let centerY = font.capHeight / 2
    attachment.bounds = NSRect(
      x: 0,
      y: centerY - diameter / 2,
      width: diameter,
      height: diameter
    )

    return attachment
  }

  /// An `NSTextAttachment` containing an SF Symbol icon for the instance.
  static func iconAttachment(symbolName: String, diameter: CGFloat = 12) -> NSTextAttachment {
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: diameter, weight: .regular)
    let image =
      NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
      .withSymbolConfiguration(symbolConfig)
      ?? NSImage(size: NSSize(width: diameter, height: diameter))

    let attachment = NSTextAttachment()
    attachment.image = image

    // Use the image's actual size so non-square SF Symbols (e.g. "macbook.gen2")
    // are rendered at their natural aspect ratio instead of being squished.
    let symbolSize = image.size
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let centerY = font.capHeight / 2
    attachment.bounds = NSRect(
      x: 0,
      y: centerY - symbolSize.height / 2,
      width: symbolSize.width,
      height: symbolSize.height
    )

    return attachment
  }

  // MARK: - Status Header

  /// Builds the status-line attributed string (dot + text).
  static func statusLine(
    dotColor: NSColor,
    text: String
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()
    result.append(NSAttributedString(attachment: dotAttachment(color: dotColor)))
    result.append(NSAttributedString(string: " " + text))
    return result
  }

  /// Builds the stats-line attributed string.
  static func statsLine(totalQueries: Int, totalBlocked: Int) -> NSAttributedString {
    let queriesText = totalQueries.formatted(.number.notation(.compactName))
    let blockedText = totalBlocked.formatted(.number.notation(.compactName))
    let pctText: String
    if totalQueries > 0 {
      let pct = Double(totalBlocked) / Double(totalQueries) * 100
      pctText = String(format: "%.0f%%", pct)
    } else {
      pctText = "0%"
    }

    let string = "\(queriesText) queries / \(blockedText) blocked · \(pctText)"
    let attr = NSMutableAttributedString(string: string)
    let fullRange = NSRange(location: 0, length: attr.length)

    attr.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), range: fullRange)
    attr.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: fullRange)

    return attr
  }

  // MARK: - Instances Section

  /// Builds the "INSTANCES" group label.
  static func instancesGroupLabel() -> NSAttributedString {
    let attr = NSMutableAttributedString(string: "INSTANCES")
    let fullRange = NSRange(location: 0, length: attr.length)
    attr.addAttribute(
      .font,
      value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
      range: fullRange
    )
    attr.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: fullRange)
    return attr
  }

  /// Builds a per-instance attributed string (dot + optional icon + label).
  static func instanceLine(dotColor: NSColor, icon: String? = nil, label: String) -> NSAttributedString {
    let result = NSMutableAttributedString()
    result.append(NSAttributedString(attachment: dotAttachment(color: dotColor)))
    if let icon, !icon.isEmpty {
      result.append(NSAttributedString(string: " "))
      result.append(NSAttributedString(attachment: iconAttachment(symbolName: icon)))
    }
    result.append(NSAttributedString(string: " " + label))
    return result
  }

  // MARK: - Timestamp

  /// Returns a relative time string for the elapsed interval since the given date.
  /// Examples: "10 sec. ago", "2 min. ago", "1 hour ago", "1 day ago".
  static func relativeTimestamp(since date: Date) -> String {
    date.formatted(
      .relative(presentation: .numeric, unitsStyle: .abbreviated)
    )
  }
}
