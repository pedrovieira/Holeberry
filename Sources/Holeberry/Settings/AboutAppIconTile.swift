import SwiftUI

/// A macOS-app-icon-shaped vibrancy tile with the Holeberry logo
/// centered on top, mirroring the Durations tab's visual effect stage.
struct AboutAppIconTile: View {
  static let side: CGFloat = 120
  static let cornerRadius: CGFloat = side * 0.2237
  static let logoSize: CGFloat = side * 0.6875  // 44/64 ratio from the original design

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Image("holeberry-logo")
      .resizable()
      .scaledToFit()
      .frame(width: Self.logoSize, height: Self.logoSize)
      // Directional shadow on the logo itself (follows the berry glyph's
      // alpha silhouette): plain black at mode-specific opacity reads as
      // crisp depth in dark mode instead of a light halo.
      .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 10, y: 3)
      .frame(width: Self.side, height: Self.side)
      .background {
        ZStack {
          VisualEffectView(
            material: colorScheme == .dark ? .underWindowBackground : .hudWindow,
            blendingMode: .behindWindow)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
      .overlay {
        // Top-light / bottom-neutral hairline, like macOS icon bezels —
        // sells the "glass" read, especially against dark backgrounds.
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
          .strokeBorder(
            LinearGradient(
              colors: [
                Color.white.opacity(colorScheme == .dark ? 0.18 : 0.35),
                Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.10)
              ],
              startPoint: .top,
              endPoint: .bottom
            ),
            lineWidth: 1
          )
      }
  }
}
