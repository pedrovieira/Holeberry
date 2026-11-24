import Foundation

/// Typed errors for app operations that are independent of Pi-hole.
public enum HoleberryError: Error, LocalizedError, Equatable {
  case storageUnavailable
  /// The configured server count already reached the app-wide limit.
  case maxServersReached(max: Int)

  public var errorDescription: String? {
    switch self {
    case .storageUnavailable:
      return "Shared storage is not ready. Quit and reopen Holeberry to retry."
    case .maxServersReached(let max):
      return "Holeberry supports up to \(max) Pi-hole instances. Remove one before adding another."
    }
  }
}
