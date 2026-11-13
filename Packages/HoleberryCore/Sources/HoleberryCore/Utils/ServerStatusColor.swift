import AppKit
import SwiftUI

/// Shared status palette for AppKit menus and SwiftUI views.
public enum ServerStatusColor: Sendable {
  case healthy
  case partial
  case offline
  case inactive

  public var nsColor: NSColor {
    switch self {
    case .healthy: return .systemGreen
    case .partial: return NSColor(calibratedRed: 1, green: 0.624, blue: 0.039, alpha: 1)
    case .offline: return .systemRed
    case .inactive: return .systemGray
    }
  }

  public var color: Color {
    Color(nsColor: nsColor)
  }
}
