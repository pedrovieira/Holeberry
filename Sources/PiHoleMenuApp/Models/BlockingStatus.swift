import Foundation

/// Whether Pi-hole blocking is enabled or disabled, with an optional server-reported remaining time.
enum BlockingStatus: Equatable {
  case enabled
  case disabled(remainingSeconds: TimeInterval?)
}
