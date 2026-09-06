import Defaults
import Foundation

/// Single owner of "what counts as due" for automatic gravity updates.
/// Launch, wake, and the internal one-shot timer all funnel through
/// `checkNow()`.
@MainActor
public protocol GravityCadenceScheduling: AnyObject {
  /// Check for a due run at launch (covers cold launch + a missed cadence
  /// while quit). Wake observation is wired by the app layer.
  func start()
  /// Call when the user changes the cadence in Settings.
  func cadenceDidChange()
  /// The one due-check. Safe to call from launch, wake, and the timer.
  func checkNow()
}

/// Default `GravityCadenceScheduling`; one per process, wired at the
/// composition root.
@MainActor
public final class LiveGravityCadenceScheduler: GravityCadenceScheduling {
  private let defaultsSuite: UserDefaults
  private let now: () -> Date
  private let sleep: (TimeInterval) async throws -> Void
  private let triggerUpdate: @MainActor () async -> [UUID: GravityUpdateOutcome]
  private let onOutcomes: @MainActor ([UUID: GravityUpdateOutcome]) -> Void

  private var pendingTask: Task<Void, Never>?
  private var checkInFlight = false

  /// Minimum re-fire distance; prevents wake + timer racing into a tight loop.
  private static let minimumFireDelay: TimeInterval = 60

  public init(
    defaultsSuite: UserDefaults = .standard,
    now: @escaping () -> Date = { Date() },
    sleep: @escaping (TimeInterval) async throws -> Void = { try await sleepForSeconds($0) },
    triggerUpdate: @escaping @MainActor () async -> [UUID: GravityUpdateOutcome],
    onOutcomes: @escaping @MainActor ([UUID: GravityUpdateOutcome]) -> Void
  ) {
    self.defaultsSuite = defaultsSuite
    self.now = now
    self.sleep = sleep
    self.triggerUpdate = triggerUpdate
    self.onOutcomes = onOutcomes
  }

  public func start() {
    checkNow()
  }

  public func cadenceDidChange() {
    let cadence = Defaults[.gravityUpdateCadence(suite: defaultsSuite)]
    guard let interval = cadence.intervalSeconds else {
      pendingTask?.cancel()
      pendingTask = nil
      Defaults[.gravityUpdateNextDue(suite: defaultsSuite)] = nil
      return
    }
    // Selecting a cadence does NOT run immediately — the first automatic
    // update fires one full interval from enabling.
    Defaults[.gravityUpdateNextDue(suite: defaultsSuite)] = now().addingTimeInterval(interval)
    armTimer(interval: interval)
  }

  public func checkNow() {
    let cadence = Defaults[.gravityUpdateCadence(suite: defaultsSuite)]
    guard let interval = cadence.intervalSeconds else { return }  // .never
    guard !checkInFlight else { return }  // in-flight run re-arms itself
    let due = Defaults[.gravityUpdateNextDue(suite: defaultsSuite)] ?? .distantPast
    guard now() >= due else {
      armTimer(interval: interval)
      return
    }
    runUpdate(cadence: cadence, interval: interval)
  }

  /// Runs one update, then re-arms if the cadence is unchanged. Anchoring
  /// `nextDue` to NOW (not the missed due date) gives "catch up once": three
  /// missed 6h periods fire one run, then the interval resumes.
  private func runUpdate(cadence: GravityUpdateCadence, interval: TimeInterval) {
    checkInFlight = true
    Task { [weak self] in
      guard let self else { return }
      defer { self.checkInFlight = false }
      let outcomes = await self.triggerUpdate()
      if Defaults[.gravityUpdateCadence(suite: self.defaultsSuite)] == cadence {
        Defaults[.gravityUpdateNextDue(suite: self.defaultsSuite)] =
          self.now().addingTimeInterval(interval)
        self.armTimer(interval: interval)
      }
      // Failure still advances nextDue (above) — avoids hammering an
      // unreachable server — but the outcome is always reported.
      self.onOutcomes(outcomes)
    }
  }

  private func armTimer(interval: TimeInterval) {
    pendingTask?.cancel()
    let due = Defaults[.gravityUpdateNextDue(suite: defaultsSuite)] ?? now().addingTimeInterval(interval)
    let fireIn = max(due.timeIntervalSince(now()), Self.minimumFireDelay)
    pendingTask = Task { [weak self] in
      guard let self else { return }
      try? await self.sleep(fireIn)
      guard !Task.isCancelled else { return }
      self.checkNow()
    }
  }
}
