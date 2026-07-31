import Foundation
import Testing

@testable import HoleberryCore

/// Real-time tests for the production `TaskPollScheduler`.
///
/// The poller itself is tested with `MockPollScheduler` (zero real time); here we
/// verify the real timing primitive: tick immediately on start, repeat at the
/// interval, stop, and replace-on-restart. Small intervals keep the suite fast,
/// and assertions use generous margins so a loaded CI machine does not produce
/// false failures. Every test stops its scheduler so no loop task outlives the test.
@MainActor
@Suite("TaskPollScheduler")
struct TaskPollSchedulerTests {
  /// Waits in real time until `condition` is true or `timeout` elapses.
  private func waitFor(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while condition() == false, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test("isRunning is false before start")
  func notRunningInitially() {
    let scheduler = TaskPollScheduler()
    #expect(scheduler.isRunning == false)
  }

  @Test("stop when not running is a safe no-op")
  func stopWhenNotRunningIsSafe() {
    let scheduler = TaskPollScheduler()
    scheduler.stop()
    #expect(scheduler.isRunning == false)
  }

  @Test("onTick fires immediately, before the interval elapses", .timeLimit(.minutes(1)))
  func ticksImmediatelyOnStart() async throws {
    let scheduler = TaskPollScheduler()
    defer { scheduler.stop() }
    var tickCount = 0
    scheduler.start(interval: 0.2) { tickCount += 1 }

    // Yield until the main actor has run the loop's first onTick. The interval is
    // 0.2s, so a second tick cannot arrive during these yields — if the loop slept
    // before ticking, the count would still be zero here.
    for _ in 0..<100 {
      if tickCount >= 1 { break }
      await Task.yield()
    }
    #expect(tickCount == 1)
  }

  @Test("onTick repeats at the configured interval", .timeLimit(.minutes(1)))
  func ticksRepeatedlyAtInterval() async throws {
    let scheduler = TaskPollScheduler()
    defer { scheduler.stop() }
    var tickCount = 0
    scheduler.start(interval: 0.05) { tickCount += 1 }
    #expect(scheduler.isRunning == true)

    // Three ticks need ~100ms; allow up to 2s on a loaded machine.
    try await waitFor { tickCount >= 3 }
    #expect(tickCount >= 3)
    // A missing sleep in the loop would spin thousands of ticks in the same window.
    #expect(tickCount <= 5)
  }

  @Test("stop cancels further ticks", .timeLimit(.minutes(1)))
  func stopCancelsFurtherTicks() async throws {
    let scheduler = TaskPollScheduler()
    defer { scheduler.stop() }
    var tickCount = 0
    scheduler.start(interval: 0.05) { tickCount += 1 }

    try await waitFor { tickCount >= 2 }
    scheduler.stop()
    let stoppedCount = tickCount
    #expect(scheduler.isRunning == false)

    // No tick may fire after stop; wait several intervals to be sure.
    try await Task.sleep(for: .milliseconds(200))
    #expect(tickCount == stoppedCount)
  }

  @Test("start replaces the previous loop", .timeLimit(.minutes(1)))
  func startReplacesPreviousLoop() async throws {
    let scheduler = TaskPollScheduler()
    defer { scheduler.stop() }
    var tickCount = 0

    // Fast loop first, then a slow loop. If the first loop were not replaced, it
    // would keep ticking every 0.05s; the replacement must cancel it.
    scheduler.start(interval: 0.05) { tickCount += 1 }
    scheduler.start(interval: 5.0) { tickCount += 1 }

    try await Task.sleep(for: .milliseconds(200))
    #expect(tickCount == 1)
  }
}
