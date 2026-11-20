import Foundation

/// Typed errors for app operations that are independent of Pi-hole.
public enum HoleberryError: Error, LocalizedError, Equatable {
  case storageUnavailable

  public var errorDescription: String? {
    switch self {
    case .storageUnavailable:
      return "Shared storage is not ready. Quit and reopen Holeberry to retry."
    }
  }
}
