import HoleberryCore
import SwiftUI

extension ConnectionStatus {
  var color: Color {
    switch self {
    case .connected: return .green
    case .disconnected: return .red
    case .unknown: return .gray
    }
  }
}
