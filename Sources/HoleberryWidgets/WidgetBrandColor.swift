import SwiftUI

/// Shared Holeberry colors for widget surfaces and content.
enum WidgetBrandColor {
  case tileStart
  case tileEnd
  case primaryText
  case secondaryText
  case blocked
  case divider

  func color(for colorScheme: ColorScheme) -> Color {
    let isDark = colorScheme == .dark
    switch self {
    case .tileStart:
      return Color(
        .sRGB,
        red: (isDark ? 58 : 243) / 255.0,
        green: (isDark ? 19 : 236) / 255.0,
        blue: (isDark ? 112 : 255) / 255.0
      )
    case .tileEnd:
      return Color(
        .sRGB,
        red: (isDark ? 20 : 226) / 255.0,
        green: (isDark ? 6 : 210) / 255.0,
        blue: (isDark ? 47 : 250) / 255.0
      )
    case .primaryText:
      return Color(
        .sRGB,
        red: (isDark ? 245 : 42) / 255.0,
        green: (isDark ? 240 : 15) / 255.0,
        blue: (isDark ? 255 : 85) / 255.0
      )
    case .secondaryText:
      return Self.primaryText.color(for: colorScheme).opacity(0.65)
    case .blocked:
      return Color(
        .sRGB,
        red: (isDark ? 242 : 176) / 255.0,
        green: (isDark ? 123 : 38) / 255.0,
        blue: (isDark ? 201 : 138) / 255.0
      )
    case .divider:
      return isDark ? .white.opacity(0.14) : Self.primaryText.color(for: colorScheme).opacity(0.15)
    }
  }

  static func tileGradient(for colorScheme: ColorScheme) -> LinearGradient {
    LinearGradient(
      colors: [tileStart.color(for: colorScheme), tileEnd.color(for: colorScheme)],
      startPoint: .top,
      endPoint: .bottom
    )
  }
}
