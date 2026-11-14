import SwiftUI

/// The point size of a widget preview surface.
///
/// WidgetKit does not expose widget sizes in points, and SwiftUI's `frame`
/// modifier takes `width` and `height` as separate values, so a size travels as
/// one struct and is applied through ``SwiftUI/View/widgetPreviewFrame(_:)``.
struct WidgetPreviewSize {
  let width: CGFloat
  let height: CGFloat

  /// The macOS `systemSmall` widget (170 x 170 points).
  static let systemSmall = WidgetPreviewSize(width: 170, height: 170)
}

extension View {
  /// Frames the view at a fixed widget preview size.
  func widgetPreviewFrame(_ size: WidgetPreviewSize) -> some View {
    frame(width: size.width, height: size.height)
  }
}
