import Foundation
import Testing

@testable import HoleberryCore

@Suite("TempUnblockRecord")
struct TempUnblockRecordTests {
  @Test func codableRoundTrip() throws {
    let record = TempUnblockRecord(
      domain: "doubleclick.net",
      uuid: "via holeberryapp.com / test-uuid",
      startDateUTC: Date(),
      durationSeconds: 300,
      pendingRemoval: true,
      retryCount: 2,
      ownsAllowEntry: false
    )
    let data = try TestJSON.encoder.encode(record)
    let decoded = try TestJSON.decoder.decode(TempUnblockRecord.self, from: data)
    #expect(decoded.domain == record.domain)
    #expect(decoded.uuid == record.uuid)
    #expect(decoded.durationSeconds == record.durationSeconds)
    #expect(decoded.pendingRemoval == record.pendingRemoval)
    #expect(decoded.retryCount == record.retryCount)
    #expect(decoded.ownsAllowEntry == record.ownsAllowEntry)
    #expect(abs(decoded.startDateUTC.timeIntervalSince(record.startDateUTC)) < 0.001)
  }

  @Test func defaults() {
    let record = TempUnblockRecord(
      domain: "ads.com",
      uuid: "via holeberryapp.com / uuid-2",
      startDateUTC: Date(),
      durationSeconds: 60
    )
    #expect(record.pendingRemoval == false)
    #expect(record.retryCount == 0)
    #expect(record.ownsAllowEntry == true, "Records written now own the allow entry they track")
  }

  @Test func decodesRecordWithoutOwnershipKey() throws {
    // Records persisted by builds that predate the v5 add probe carry no
    // ownership key and must not claim the allow entry they point at.
    let legacy = Data(
      #"""
      {"domain":"permanent.com","uuid":"via holeberryapp.com / legacy","startDateUTC":780000000,
       "durationSeconds":300,"pendingRemoval":false,"retryCount":0}
      """#.utf8
    )
    let decoded = try TestJSON.decoder.decode(TempUnblockRecord.self, from: legacy)
    #expect(decoded.domain == "permanent.com")
    #expect(decoded.pendingRemoval == false)
    #expect(decoded.ownsAllowEntry == false)
  }
}
