import Foundation

/// Suspends via `Task.sleep(nanoseconds:)` — `Task.sleep(for:)` crashes with
/// cross-module inlining on Swift 6.3; revisit when fixed. Negatives clamp.
public func sleepForSeconds(_ seconds: TimeInterval) async throws {
  try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
}
