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
  static func iconAttachment(symbolName: String, diameter: CGFloat = 12, color: NSColor? = nil) -> NSTextAttachment {
    var symbolConfig = NSImage.SymbolConfiguration(pointSize: diameter, weight: .regular)
    if let color {
      symbolConfig = symbolConfig.applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
    }
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

    // Cap the symbol height at the font's ascender: at a 12pt config some
    // symbols render taller than the line, which grows the first line fragment
    // and pushes the subtitle line of two-line menu items below the row's
    // visible bounds. Scaling preserves the aspect ratio.
    let maxHeight = font.ascender
    let scale = min(1, maxHeight / symbolSize.height)
    let scaledSize = NSSize(
      width: symbolSize.width * scale,
      height: symbolSize.height * scale
    )

    attachment.bounds = NSRect(
      x: 0,
      y: centerY - scaledSize.height / 2,
      width: scaledSize.width,
      height: scaledSize.height
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

  /// Builds a two-line per-instance attributed string: dot + (icon) + label on the first line,
  /// and individual blocking stats on the second line.
  static func instanceLineWithStats(
    dotColor: NSColor,
    icon: String? = nil,
    label: String,
    totalQueries: Int,
    totalBlocked: Int
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()

    // Line 1: dot + (icon) + label (same as instanceLine)
    result.append(NSAttributedString(attachment: dotAttachment(color: dotColor)))
    if let icon, !icon.isEmpty {
      result.append(NSAttributedString(string: " "))
      result.append(NSAttributedString(attachment: iconAttachment(symbolName: icon)))
    }
    result.append(NSAttributedString(string: " " + label))

    // Line break
    result.append(NSAttributedString(string: "\n"))

    // Extra breathing room between the instance name and its stats line.
    let firstLineRange = NSRange(location: 0, length: result.length)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.paragraphSpacing = 4
    result.addAttribute(.paragraphStyle, value: paragraphStyle, range: firstLineRange)

    // Line 2: stats in small secondary text
    let queriesText = totalQueries.formatted(.number.notation(.compactName))
    let blockedText = totalBlocked.formatted(.number.notation(.compactName))
    let pctText: String
    if totalQueries > 0 {
      let pct = Double(totalBlocked) / Double(totalQueries) * 100
      pctText = String(format: "%.0f%%", pct)
    } else {
      pctText = "0%"
    }

    let statsString = "\(queriesText) queries / \(blockedText) blocked · \(pctText)"
    let statsAttr: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
      .foregroundColor: NSColor.secondaryLabelColor
    ]
    result.append(NSAttributedString(string: statsString, attributes: statsAttr))

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
