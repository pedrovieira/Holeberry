import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("TempUnblockStore")
struct TempUnblockStoreTests {
  private func expectRecordEquals(_ actual: TempUnblockRecord, _ expected: TempUnblockRecord) {
    #expect(actual.domain == expected.domain)
    #expect(actual.uuid == expected.uuid)
    #expect(actual.startDateUTC == expected.startDateUTC)
    #expect(actual.durationSeconds == expected.durationSeconds)
    #expect(actual.pendingRemoval == expected.pendingRemoval)
    #expect(actual.retryCount == expected.retryCount)
  }

  @Test("loads existing arrays with all fields")
  func loadsExistingArraysWithAllFields() {
    let appLocalSuite = TestDefaults.makeSuite()
    let storage = makeTestTempUnblockStore(suite: appLocalSuite)
    let serverID = UUID()
    let records = [
      TempUnblockRecord(
        domain: "Example.COM",
        uuid: "token-1",
        startDateUTC: Date(timeIntervalSince1970: 1_700_000_000),
        durationSeconds: 3_600,
        pendingRemoval: true,
        retryCount: 2
      ),
      TempUnblockRecord(
        domain: "mixed.Case.Example",
        uuid: "token-2",
        startDateUTC: Date(timeIntervalSince1970: 1_700_000_500),
        durationSeconds: 604_800,
        pendingRemoval: false,
        retryCount: 0
      )
    ]
    Defaults[.tempUnblocks(for: serverID, suite: appLocalSuite)] = records

    let loadedRecords = storage.loadTemporaryUnblocks(for: serverID)
    #expect(loadedRecords.count == 2)
    for (index, expected) in records.enumerated() {
      expectRecordEquals(loadedRecords[index], expected)
    }
    // A missing server key reads as empty.
    #expect(storage.loadTemporaryUnblocks(for: UUID()).isEmpty)
  }

  @Test("save uses existing keys and persists empty arrays")
  func saveUsesExistingKeys() {
    let appLocalSuite = TestDefaults.makeSuite()
    let storage = makeTestTempUnblockStore(suite: appLocalSuite)
    let serverID = UUID()
    let record = TempUnblockRecord(
      domain: "save.example",
      uuid: "token-save",
      startDateUTC: Date(timeIntervalSince1970: 1_700_001_000),
      durationSeconds: 300,
      pendingRemoval: true,
      retryCount: 1
    )

    storage.saveTemporaryUnblocks([record], for: serverID)

    let savedRecords: [TempUnblockRecord] = Defaults[.tempUnblocks(for: serverID, suite: appLocalSuite)]
    #expect(savedRecords.count == 1)
    expectRecordEquals(savedRecords[0], record)

    // Replacing with an empty array persists an empty array under the same key.
    storage.saveTemporaryUnblocks([], for: serverID)
    #expect(Defaults[.tempUnblocks(for: serverID, suite: appLocalSuite)].isEmpty)
    #expect(appLocalSuite.object(forKey: "tempUnblocks-\(serverID.uuidString)") != nil)
  }

  @Test("loads read the current backing store")
  func loadsReadCurrentBackingStore() {
    let appLocalSuite = TestDefaults.makeSuite()
    let storage = makeTestTempUnblockStore(suite: appLocalSuite)
    let serverID = UUID()
    #expect(storage.loadTemporaryUnblocks(for: serverID).isEmpty)

    let records = [
      TempUnblockRecord(
        domain: "external.example",
        uuid: "token-external",
        startDateUTC: Date(timeIntervalSince1970: 1_700_002_000),
        durationSeconds: 120
      )
    ]
    Defaults[.tempUnblocks(for: serverID, suite: appLocalSuite)] = records

    let loadedRecords = storage.loadTemporaryUnblocks(for: serverID)
    #expect(loadedRecords.count == 1)
    expectRecordEquals(loadedRecords[0], records[0])
  }

  @Test("records are separated per server")
  func recordsAreSeparatedPerServer() {
    let appLocalSuite = TestDefaults.makeSuite()
    let storage = makeTestTempUnblockStore(suite: appLocalSuite)
    let firstID = UUID()
    let secondID = UUID()
    let secondRecords = [
      TempUnblockRecord(
        domain: "second-server.example",
        uuid: "second-token",
        startDateUTC: Date(timeIntervalSince1970: 1_700_004_000),
        durationSeconds: 7200,
        retryCount: 3
      )
    ]
    Defaults[.tempUnblocks(for: secondID, suite: appLocalSuite)] = secondRecords

    let newRecord = TempUnblockRecord(
      domain: "first-server.example",
      uuid: "first-token",
      startDateUTC: Date(timeIntervalSince1970: 1_700_005_000),
      durationSeconds: 600
    )
    storage.saveTemporaryUnblocks([newRecord], for: firstID)

    let firstRecords = storage.loadTemporaryUnblocks(for: firstID)
    #expect(firstRecords.count == 1)
    expectRecordEquals(firstRecords[0], newRecord)

    // Another server's records are intact.
    let remainingSecondRecords = storage.loadTemporaryUnblocks(for: secondID)
    #expect(remainingSecondRecords.count == 1)
    expectRecordEquals(remainingSecondRecords[0], secondRecords[0])
  }

  @Test("temporary records read only the app-local suite", arguments: [true, false])
  func temporaryUnblocksUseOnlyAppLocalSuite(intendedStorePopulated: Bool) {
    let appLocalSuite = TestDefaults.makeSuite()
    let decoySuite = TestDefaults.makeSuite()
    let serverID = UUID()
    let intended = [
      TempUnblockRecord(
        domain: "Intended.Example",
        uuid: "intended-token",
        startDateUTC: Date(timeIntervalSince1970: 1_700_009_000),
        durationSeconds: 900,
        pendingRemoval: true,
        retryCount: 2
      ),
      TempUnblockRecord(
        domain: "Second.Example",
        uuid: "second-token",
        startDateUTC: Date(timeIntervalSince1970: 1_700_009_500),
        durationSeconds: 3_600
      )
    ]
    let decoy = [
      TempUnblockRecord(
        domain: "decoy.example",
        uuid: "decoy-token",
        startDateUTC: Date(timeIntervalSince1970: 1_600_000_000),
        durationSeconds: 60
      )
    ]
    Defaults[.tempUnblocks(for: serverID, suite: decoySuite)] = decoy
    if intendedStorePopulated {
      Defaults[.tempUnblocks(for: serverID, suite: appLocalSuite)] = intended
    }
    let storage = makeTestTempUnblockStore(suite: appLocalSuite)

    let loaded = storage.loadTemporaryUnblocks(for: serverID)

    if intendedStorePopulated {
      #expect(loaded.count == intended.count)
      for (index, expected) in intended.enumerated() where index < loaded.count {
        expectRecordEquals(loaded[index], expected)
      }
    } else {
      #expect(
        loaded.isEmpty,
        "temporary records must never fall back to another suite")
    }
  }
}
