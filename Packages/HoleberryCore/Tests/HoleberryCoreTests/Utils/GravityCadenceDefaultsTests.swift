import Defaults
import Foundation
import HoleberryCore
import Testing

@Suite("Gravity cadence Defaults keys", .serialized)
@MainActor
struct GravityCadenceDefaultsTests {
  @Test("Cadence defaults to never")
  func defaultCadence() {
    let suite = TestDefaults.makeSuite()
    #expect(Defaults[.gravityUpdateCadence(suite: suite)] == .never)
  }

  @Test("Next-due defaults to nil and round-trips")
  func nextDueRoundTrip() {
    let suite = TestDefaults.makeSuite()
    #expect(Defaults[.gravityUpdateNextDue(suite: suite)] == nil)
    let due = Date(timeIntervalSince1970: 1_700_000_000)
    Defaults[.gravityUpdateNextDue(suite: suite)] = due
    #expect(Defaults[.gravityUpdateNextDue(suite: suite)] == due)
    Defaults[.gravityUpdateNextDue(suite: suite)] = nil
    #expect(Defaults[.gravityUpdateNextDue(suite: suite)] == nil)
  }

  @Test("Cadence round-trips through the suite")
  func cadenceRoundTrip() {
    let suite = TestDefaults.makeSuite()
    Defaults[.gravityUpdateCadence(suite: suite)] = .daily
    #expect(Defaults[.gravityUpdateCadence(suite: suite)] == .daily)
  }
}
