import Foundation

/// Abstraction over the periodic trigger that drives `ServerStatusPoller` polls.
///
/// The poller owns *what* to do on each tick (`onTick`); the scheduler owns *when*
/// ticks happen. Production uses `TaskPollScheduler`; tests inject a mock that fires
/// ticks manually, so polling behavior is testable without real time passing.
@MainActor
public protocol PollScheduler: AnyObject {
  /// Whether a loop is currently running (started via `start(interval:onTick:)`
  /// and not yet stopped via `stop()`).
  var isRunning: Bool { get }

  /// Begins invoking `onTick` immediately, then once every `interval` seconds, until
  /// `stop()` is called. Calling `start` again replaces the previous loop.
  func start(interval: TimeInterval, onTick: @escaping @MainActor () async -> Void)

  /// Cancels the loop started by `start()`. Safe to call when not running.
  func stop()
}

/// Default `PollScheduler` backed by a `Task` loop and `Task.sleep`.
@MainActor
public final class TaskPollScheduler: PollScheduler {
  private var task: Task<Void, Never>?

  /// True while the loop task exists. The loop only ends via `stop()`, which
  /// cancels and clears the task, so `task != nil` is equivalent to "running".
  public var isRunning: Bool { task != nil }

  public init() {}

  public func start(interval: TimeInterval, onTick: @escaping @MainActor () async -> Void) {
    stop()
    task = Task { [weak self] in
      while !Task.isCancelled {
        guard self != nil else { return }
        await onTick()
        try? await sleepForSeconds(interval)
      }
    }
  }

  public func stop() {
    task?.cancel()
    task = nil
  }
}
