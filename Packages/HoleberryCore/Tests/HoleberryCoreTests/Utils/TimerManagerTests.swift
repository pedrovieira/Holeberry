import Foundation
import Testing

@testable import HoleberryCore

@Suite("TimerManager")
struct TimerManagerTests {
  @Test("starts not running")
  func startsNotRunning() {
    let manager = TimerManager()
    #expect(!manager.isRunning)
    #expect(manager.remainingSeconds == 0)
    #expect(manager.totalDuration == nil)
  }

  @Test("formattedTime returns empty when not running")
  func formattedTimeWhenNotRunning() {
    let manager = TimerManager()
    #expect(manager.formattedTime.isEmpty)
  }

  @Test("start with indefinite duration")
  func startIndefinite() {
    let manager = TimerManager()
    manager.start(duration: nil)
    #expect(manager.isRunning)
    #expect(manager.totalDuration == nil)
    #expect(manager.remainingSeconds == 0)
    #expect(manager.formattedTime == "0s")
  }

  @Test("start with timed duration sets remaining")
  func startTimed() {
    let manager = TimerManager()
    manager.start(duration: 300)
    #expect(manager.isRunning)
    #expect(manager.totalDuration == 300)
    #expect(manager.remainingSeconds == 300)
  }

  @Test("cancel clears state")
  func cancel() {
    let manager = TimerManager()
    manager.start(duration: nil)
    #expect(manager.isRunning)
    manager.cancel()
    #expect(!manager.isRunning)
    #expect(manager.remainingSeconds == 0)
    #expect(manager.totalDuration == nil)
    #expect(manager.formattedTime.isEmpty)
  }

  @Test("formattedTime for seconds-only duration")
  func formattedTimeSeconds() {
    let manager = TimerManager()
    manager.start(duration: 45)
    manager.remainingSeconds = 30
    #expect(manager.formattedTime == "30s")
  }

  @Test("formattedTime for minutes and seconds")
  func formattedTimeMinutes() {
    let manager = TimerManager()
    manager.start(duration: 300)
    manager.remainingSeconds = 185
    #expect(manager.formattedTime == "3:05")
  }

  @Test("formattedTime rounds up")
  func formattedTimeRoundsUp() {
    let manager = TimerManager()
    manager.start(duration: 10)
    manager.remainingSeconds = 9.2
    #expect(manager.formattedTime == "10s")
  }
}
