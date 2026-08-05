import Foundation
import Testing

@testable import HoleberryCore

@Suite("Unblock Duration Entry")
struct UnblockDurationEntryTests {
  @Test func defaultEntriesHaveExpectedDurations() {
    let seconds = UnblockDurationEntry.defaultEntries.map(\.seconds)
    #expect(seconds == [10, 30, 300])
  }

  @Test func defaultEntriesHaveStableIDs() {
    let ids = UnblockDurationEntry.defaultEntries.map(\.id)
    #expect(
      ids == [
        UnblockDurationEntry.default10sID,
        UnblockDurationEntry.default30sID,
        UnblockDurationEntry.default5mID
      ])
  }

  @Test func defaultEntriesAreOrdered() {
    // Order matters: it is the menu order.
    #expect(UnblockDurationEntry.defaultEntries[0].seconds == 10)
    #expect(UnblockDurationEntry.defaultEntries[1].seconds == 30)
    #expect(UnblockDurationEntry.defaultEntries[2].seconds == 300)
  }

  @Test func equalityUsesIDAndSeconds() {
    let first = UnblockDurationEntry(id: UnblockDurationEntry.default10sID, seconds: 10)
    let second = UnblockDurationEntry(id: UnblockDurationEntry.default10sID, seconds: 10)
    #expect(first == second)
    #expect(first != UnblockDurationEntry(seconds: 10))
  }

  @Test func customEntriesGetUniqueIDs() {
    let first = UnblockDurationEntry(seconds: 45)
    let second = UnblockDurationEntry(seconds: 45)
    #expect(first.id != second.id)
  }
}
