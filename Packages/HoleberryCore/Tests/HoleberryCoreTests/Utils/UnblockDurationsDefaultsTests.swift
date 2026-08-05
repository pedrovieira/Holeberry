import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@Suite("Unblock Durations Defaults")
@MainActor
struct UnblockDurationsDefaultsTests {
  @Test func defaultsToThreeStandardDurations() {
    let suite = TestDefaults.makeSuite()
    let durations = Defaults[.unblockDurations(suite: suite)]
    #expect(durations == UnblockDurationEntry.defaultEntries)
    #expect(durations.map(\.seconds) == [10, 30, 300])
  }

  @Test func saveAndLoad() {
    let suite = TestDefaults.makeSuite()
    let custom = [
      UnblockDurationEntry(seconds: 45),
      UnblockDurationEntry(seconds: 600)
    ]
    Defaults[.unblockDurations(suite: suite)] = custom
    #expect(Defaults[.unblockDurations(suite: suite)] == custom)
  }

  @Test func overwrite() {
    let suite = TestDefaults.makeSuite()
    Defaults[.unblockDurations(suite: suite)] = [UnblockDurationEntry(seconds: 45)]
    Defaults[.unblockDurations(suite: suite)] = [UnblockDurationEntry(seconds: 600)]
    #expect(Defaults[.unblockDurations(suite: suite)].map(\.seconds) == [600])
  }
}
