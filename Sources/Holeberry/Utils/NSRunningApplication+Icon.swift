import AppKit

extension NSRunningApplication {
  static let menuBarIconSize = NSSize(width: 16, height: 16)

  func resizedIcon(size: NSSize) -> NSImage? {
    guard let raw = icon?.copy() as? NSImage else { return nil }
    raw.size = size
    return raw
  }
}
