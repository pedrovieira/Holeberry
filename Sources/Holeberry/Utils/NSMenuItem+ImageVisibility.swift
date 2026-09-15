import AppKit

extension NSMenuItem {
  /// The item's image, always visible on macOS 27+, where AppKit otherwise
  /// hides menu-item images by default.
  var visibleImage: NSImage? {
    get { image }
    set {
      image = newValue
      if #available(macOS 27.0, *) {
        preferredImageVisibility = .visible
      }
    }
  }
}
