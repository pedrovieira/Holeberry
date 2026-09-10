import Defaults
import Foundation
import HoleberryCore
import Testing

/// Mutable test clock so tests can advance time deterministically.
@MainActor
private final class TestClock {
  var now = Date(timeIntervalSince1970: 1_700_000_000)
}

/// Resumable sleep seam: records requested intervals and suspends until the
/// test fires the continuation.
@MainActor
private final class SleepSpy {
  private(set) var intervals: [TimeInterval] = []
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func callAsFunction(_ interval: TimeInterval) async {
    intervals.append(interval)
    await withCheckedContinuation { continuations.append($0) }
  }

  func fireNext() {
    continuations.removeFirst().resume()
  }
}

/// Suspending trigger stub: records calls and completes on demand.
@MainActor
private final class TriggerStub {
  private(set) var callCount = 0
  private var completers: [CheckedContinuation<[UUID: GravityUpdateOutcome], Never>] = []
  var outcome: [UUID: GravityUpdateOutcome] = [:]

  func call() async -> [UUID: GravityUpdateOutcome] {
    callCount += 1
    return await withCheckedContinuation { completers.append($0) }
  }

  func completeNext() {
    completers.removeFirst().resume(returning: outcome)
  }
}

@Suite("GravityCadenceScheduler", .serialized)
@MainActor
struct GravityCadenceSchedulerTests {
  private let clock = TestClock()

  private func makeScheduler(
    suite: UserDefaults,
    sleep: SleepSpy,
    trigger: TriggerStub,
    outcomes: @escaping @MainActor ([UUID: GravityUpdateOutcome]) -> Void = { _ in }
  ) -> LiveGravityCadenceScheduler {
    LiveGravityCadenceScheduler(
      defaultsSuite: suite,
      now: { [clock] in clock.now },
      sleep: { try? await sleep($0) },
      triggerUpdate: { await trigger.call() },
      onOutcomes: { outcomes($0) }
    )
  }

  @Test("Never is a no-op: no trigger, no nextDue, no timer")
  func neverIsNoOp() {
    let suite = TestDefaults.makeSuite()
    let sleep = SleepSpy()
    let trigger = TriggerStub()
    let scheduler = makeScheduler(suite: suite, sleep: sleep, trigger: trigger)

    scheduler.start()
    scheduler.checkNow()
    scheduler.cadenceDidChange()

    #expect(trigger.callCount == 0)
    #expect(Defaults[.gravityUpdateNextDue(suite: suite)] == nil)
    #expect(sleep.intervals.isEmpty)
  }

  @Test("Enabling a cadence sets nextDue one interval out and arms the timer; no immediate run")
  func enablingArmsWithoutRunning() async {
    let suite = TestDefaults.makeSuite()
    let sleep = SleepSpy()
    let trigger = TriggerStub()
    let scheduler = makeScheduler(suite: suite, sleep: sleep, trigger: trigger)

    Defaults[.gravityUpdateCadence(suite: suite)] = .every6Hours
    scheduler.cadenceDidChange()

    // The armed one-shot resumes asynchronously on the main actor; yield until it arms.
    await waitUntil { sleep.intervals == [6 * 3600] }

    #expect(trigger.callCount == 0)
    #expect(Defaults[.gravityUpdateNextDue(suite: suite)] == clock.now.addingTimeInterval(6 * 3600))
    #expect(sleep.intervals == [6 * 3600])
  }

  @Test("Past due triggers exactly once and anchors nextDue to now")
  func catchUpOnce() async {
    let suite = TestDefaults.makeSuite()
    let sleep = SleepSpy()
    let trigger = TriggerStub()
    let scheduler = makeScheduler(suite: suite, sleep: sleep, trigger: trigger)

    Defaults[.gravityUpdateCadence(suite: suite)] = .daily
    Defaults[.gravityUpdateNextDue(suite: suite)] = clock.now.addingTimeInterval(-3 * 24 * 3600)
    scheduler.start()
    // Wait for the spawned update task to reach the trigger seam before completing it.
    await waitUntil { trigger.callCount == 1 }
    trigger.completeNext()
    await waitUntil {
      Defaults[.gravityUpdateNextDue(suite: suite)] == clock.now.addingTimeInterval(24 * 3600)
    }

    #expect(trigger.callCount == 1)
  }

  @Test("nextDue advances even when the update fails, and outcomes are reported")
  func failureAdvancesNextDue() async {
    let suite = TestDefaults.makeSuite()
    let sleep = SleepSpy()
    let trigger = TriggerStub()
    trigger.outcome = [UUID(): .failed(.network("unreachable"))]
    var reported: [UUID: GravityUpdateOutcome] = [:]
    let scheduler = makeScheduler(
      suite: suite, sleep: sleep, trigger: trigger,
      outcomes: { reported = $0 }
    )

    Defaults[.gravityUpdateCadence(suite: suite)] = .weekly
    Defaults[.gravityUpdateNextDue(suite: suite)] = clock.now.addingTimeInterval(-1)
    scheduler.checkNow()
    // Wait for the spawned update task to reach the trigger seam before completing it.
    await waitUntil { trigger.callCount == 1 }
    trigger.completeNext()
    await waitUntil { reported.count == 1 }

    #expect(Defaults[.gravityUpdateNextDue(suite: suite)] == clock.now.addingTimeInterval(7 * 24 * 3600))
  }

  @Test("Changing cadence recomputes nextDue from the new interval; Never clears")
  func cadenceChangeRecomputes() async {
    let suite = TestDefaults.makeSuite()
    let sleep = SleepSpy()
    let trigger = TriggerStub()
    let scheduler = makeScheduler(suite: suite, sleep: sleep, trigger: trigger)

    Defaults[.gravityUpdateCadence(suite: suite)] = .every6Hours
    scheduler.cadenceDidChange()
    Defaults[.gravityUpdateCadence(suite: suite)] = .weekly
    scheduler.cadenceDidChange()

    // Yield until the newest armed one-shot records its interval.
    await waitUntil { sleep.intervals.last == TimeInterval(7 * 24 * 3600) }

    #expect(Defaults[.gravityUpdateNextDue(suite: suite)] == clock.now.addingTimeInterval(7 * 24 * 3600))
    #expect(sleep.intervals.last == TimeInterval(7 * 24 * 3600))

    Defaults[.gravityUpdateCadence(suite: suite)] = .never
    scheduler.cadenceDidChange()
    #expect(Defaults[.gravityUpdateNextDue(suite: suite)] == nil)
  }

  @Test("checkNow while an update is in flight does not trigger a duplicate")
  func reentrancy() async {
    let suite = TestDefaults.makeSuite()
    let sleep = SleepSpy()
    let trigger = TriggerStub()
    let scheduler = makeScheduler(suite: suite, sleep: sleep, trigger: trigger)

    Defaults[.gravityUpdateCadence(suite: suite)] = .daily
    Defaults[.gravityUpdateNextDue(suite: suite)] = clock.now.addingTimeInterval(-1)
    scheduler.checkNow()
    // Wait for the spawned update task to reach the trigger seam before checking re-entrancy.
    await waitUntil { trigger.callCount == 1 }
    scheduler.checkNow()  // in flight — must be a no-op
    #expect(trigger.callCount == 1)
    trigger.completeNext()
    await waitUntil {
      Defaults[.gravityUpdateNextDue(suite: suite)] == clock.now.addingTimeInterval(24 * 3600)
    }
  }

  @Test("Mid-flight cadence change to weekly wins; completed run does not clobber nextDue")
  func midFlightChangeToWeekly() async {
    let suite = TestDefaults.makeSuite()
    let sleep = SleepSpy()
    let trigger = TriggerStub()
    var reported = false
    let scheduler = makeScheduler(
      suite: suite, sleep: sleep, trigger: trigger,
      outcomes: { _ in reported = true }
    )

    Defaults[.gravityUpdateCadence(suite: suite)] = .daily
    Defaults[.gravityUpdateNextDue(suite: suite)] = clock.now.addingTimeInterval(-1)
    scheduler.checkNow()
    // Wait for the spawned update task to reach the trigger seam.
    await waitUntil { trigger.callCount == 1 }
    // User changes the cadence while the update is in flight.
    Defaults[.gravityUpdateCadence(suite: suite)] = .weekly
    scheduler.cadenceDidChange()
    trigger.completeNext()
    await waitUntil { reported }

    #expect(Defaults[.gravityUpdateNextDue(suite: suite)] == clock.now.addingTimeInterval(7 * 24 * 3600))
    #expect(trigger.callCount == 1)
  }

  @Test("Mid-flight change to Never clears nextDue; completed run does not restore it")
  func midFlightChangeToNever() async {
    let suite = TestDefaults.makeSuite()
    let sleep = SleepSpy()
    let trigger = TriggerStub()
    var reported = false
    let scheduler = makeScheduler(
      suite: suite, sleep: sleep, trigger: trigger,
      outcomes: { _ in reported = true }
    )

    Defaults[.gravityUpdateCadence(suite: suite)] = .daily
    Defaults[.gravityUpdateNextDue(suite: suite)] = clock.now.addingTimeInterval(-1)
    scheduler.checkNow()
    // Wait for the spawned update task to reach the trigger seam.
    await waitUntil { trigger.callCount == 1 }
    // User disables the cadence while the update is in flight.
    Defaults[.gravityUpdateCadence(suite: suite)] = .never
    scheduler.cadenceDidChange()
    trigger.completeNext()
    await waitUntil { reported }

    #expect(Defaults[.gravityUpdateNextDue(suite: suite)] == nil)
    #expect(trigger.callCount == 1)
  }

  @Test("Firing the armed one-shot runs the due check")
  func armedTimerFires() async {
    let suite = TestDefaults.makeSuite()
    let sleep = SleepSpy()
    let trigger = TriggerStub()
    let scheduler = makeScheduler(suite: suite, sleep: sleep, trigger: trigger)

    Defaults[.gravityUpdateCadence(suite: suite)] = .every12Hours
    scheduler.cadenceDidChange()
    clock.now = clock.now.addingTimeInterval(12 * 3600)
    // Yield until the armed one-shot reaches the sleep seam before firing it.
    await waitUntil { sleep.intervals.count == 1 }
    sleep.fireNext()
    await waitUntil { trigger.callCount == 1 }
    trigger.completeNext()
    await waitUntil {
      Defaults[.gravityUpdateNextDue(suite: suite)] == clock.now.addingTimeInterval(12 * 3600)
    }
  }
}
