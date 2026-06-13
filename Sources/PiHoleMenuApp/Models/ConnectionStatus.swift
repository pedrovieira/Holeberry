import SwiftUI

enum ConnectionStatus {
  case connected
  case disconnected
  case unknown

  var color: Color {
    switch self {
    case .connected: return .green
    case .disconnected: return .red
    case .unknown: return .gray
    }
  }

  var label: String {
    switch self {
    case .connected: return "Connected"
    case .disconnected: return "Disconnected"
    case .unknown: return "Unknown"
    }
  }
}
