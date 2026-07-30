public enum ConnectionStatus {
  case connected
  case disconnected
  case unknown

  public var label: String {
    switch self {
    case .connected: return "Connected"
    case .disconnected: return "Disconnected"
    case .unknown: return "Unknown"
    }
  }
}
