import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@Suite("Unblock Current Tab Duration Selection")
struct UnblockCurrentTabDurationSelectionTests {
  @Test func indefiniteAlwaysResolvesToNil() {
    #expect(UnblockCurrentTabDurationSelection.indefinite.resolve(durations: []) == nil)
    #expect(
      UnblockCurrentTabDurationSelection.indefinite.resolve(durations: UnblockDurationEntry.defaultEntries) == nil)
  }

  @Test func entryResolvesToItsSeconds() {
    let selection = UnblockCurrentTabDurationSelection.entry(UnblockDurationEntry.default5mID)
    #expect(selection.resolve(durations: UnblockDurationEntry.defaultEntries) == 300)
  }

  @Test func deletedEntryResolvesToNil() {
    let selection = UnblockCurrentTabDurationSelection.entry(UnblockDurationEntry.default30sID)
    let without30s = UnblockDurationEntry.defaultEntries.filter { $0.id != UnblockDurationEntry.default30sID }
    #expect(selection.resolve(durations: without30s) == nil)
    #expect(selection.resolve(durations: []) == nil)
  }

  @Test func customResolvesToNilUntilPrompted() {
    #expect(UnblockCurrentTabDurationSelection.custom.resolve(durations: []) == nil)
    #expect(
      UnblockCurrentTabDurationSelection.custom.resolve(durations: UnblockDurationEntry.defaultEntries) == nil)
  }

  @Test func customNeverHealsAway() {
    #expect(UnblockCurrentTabDurationSelection.custom.healed(durations: []) == .custom)
    #expect(
      UnblockCurrentTabDurationSelection.custom.healed(durations: UnblockDurationEntry.defaultEntries) == .custom)
  }

  @Test func resolutionIsIDBasedNotSecondsBased() {
    // A re-added "5 minutes" entry gets a fresh UUID and must not satisfy an
    // old selection referencing the deleted default entry.
    let reAdded = UnblockDurationEntry(seconds: 300)
    let selection = UnblockCurrentTabDurationSelection.entry(UnblockDurationEntry.default5mID)
    #expect(selection.resolve(durations: [reAdded]) == nil)
    #expect(selection.healed(durations: [reAdded]) == .indefinite)
  }

  @Test func healKeepsValidSelections() {
    let valid = UnblockCurrentTabDurationSelection.entry(UnblockDurationEntry.default10sID)
    #expect(valid.healed(durations: UnblockDurationEntry.defaultEntries) == valid)
    #expect(UnblockCurrentTabDurationSelection.indefinite.healed(durations: []) == .indefinite)
  }

  @Test func healRepairsDanglingEntries() {
    let dangling = UnblockCurrentTabDurationSelection.entry(UnblockDurationEntry.default5mID)
    let without5m = UnblockDurationEntry.defaultEntries.filter { $0.id != UnblockDurationEntry.default5mID }
    #expect(dangling.healed(durations: without5m) == .indefinite)
    #expect(dangling.healed(durations: []) == .indefinite)
  }

  @Test func defaultsKeyDefaultsToStableFiveMinutes() {
    let suite = TestDefaults.makeSuite()
    #expect(Defaults[.unblockCurrentTabDuration(suite: suite)] == .entry(UnblockDurationEntry.default5mID))
  }

  @Test func defaultsKeyRoundTripsCodableSelections() {
    let suite = TestDefaults.makeSuite()
    Defaults[.unblockCurrentTabDuration(suite: suite)] = .entry(UnblockDurationEntry.default10sID)
    #expect(Defaults[.unblockCurrentTabDuration(suite: suite)] == .entry(UnblockDurationEntry.default10sID))
    Defaults[.unblockCurrentTabDuration(suite: suite)] = .indefinite
    #expect(Defaults[.unblockCurrentTabDuration(suite: suite)] == .indefinite)
    Defaults[.unblockCurrentTabDuration(suite: suite)] = .custom
    #expect(Defaults[.unblockCurrentTabDuration(suite: suite)] == .custom)
  }
}
