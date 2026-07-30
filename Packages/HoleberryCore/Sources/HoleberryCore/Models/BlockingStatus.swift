import Foundation

/// Whether Pi-hole blocking is enabled or disabled, with an optional server-reported remaining time.
public enum BlockingStatus: Equatable, Sendable {
  case enabled
  case disabled(remainingSeconds: TimeInterval?)
}
