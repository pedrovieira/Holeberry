import SwiftUI

/// A squared `NSVisualEffectView` used as a vibrancy stage behind opaque
/// content — e.g. the menu mock in the Durations tab and the app-icon tile
/// in the About tab. Rendering only happens during `draw()`, so the
/// appearance resolves against the actual visual context.
struct VisualEffectView: NSViewRepresentable {
  var material: NSVisualEffectView.Material = .menu
  var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
  var state: NSVisualEffectView.State = .active

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = blendingMode
    view.state = state
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.material = material
    view.blendingMode = blendingMode
    view.state = state
  }
}
