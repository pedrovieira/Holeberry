import Foundation

@testable import HoleberryCore

/// Test `PollScheduler` that records start/stop calls and lets tests fire ticks
/// manually. Mirrors the real scheduler's contract: ticks only fire while started.
@MainActor
final class MockPollScheduler: PollScheduler {
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var lastInterval: TimeInterval?
  private(set) var isRunning = false
  private var onTick: (@MainActor () async -> Void)?

  func start(interval: TimeInterval, onTick: @escaping @MainActor () async -> Void) {
    startCount += 1
    lastInterval = interval
    self.onTick = onTick
    isRunning = true
  }

  func stop() {
    stopCount += 1
    isRunning = false
  }

  /// Fires one tick. No-op while stopped, mirroring the real scheduler.
  func fireTick() async {
    guard isRunning, let onTick else { return }
    await onTick()
  }
}
