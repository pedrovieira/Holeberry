import Foundation

/// The configured servers targeted by a manager operation.
public enum ServerScope: Equatable, Sendable {
  /// Every configured server.
  case all
  /// One server by identifier, whether or not it is still configured.
  case server(UUID)
  /// No server. A selection that cannot name a server targets nothing, so
  /// operations over it contact no server and produce no result.
  case noTarget
}
