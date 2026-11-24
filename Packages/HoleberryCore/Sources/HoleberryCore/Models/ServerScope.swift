import Foundation

/// The configured servers targeted by a manager operation.
public enum ServerScope: Equatable, Sendable {
  case all
  case server(UUID)

  /// Selects the configured servers this scope targets, in saved order.
  ///
  /// A selected identifier that is not configured selects nothing, so the
  /// caller can show a "no matching server" state instead of fetching.
  public func selected(from servers: [ServerConfig]) -> [ServerConfig] {
    switch self {
    case .all:
      return servers
    case .server(let id):
      return servers.filter { $0.id == id }
    }
  }
}
