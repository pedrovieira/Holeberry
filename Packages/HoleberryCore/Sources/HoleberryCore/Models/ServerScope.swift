import Foundation

/// The configured servers targeted by a manager operation.
public enum ServerScope: Equatable, Sendable {
  case all
  case server(UUID)
}
