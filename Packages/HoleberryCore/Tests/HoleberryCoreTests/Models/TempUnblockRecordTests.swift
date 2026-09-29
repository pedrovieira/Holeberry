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
      retryCount: 2
    )
    let data = try TestJSON.encoder.encode(record)
    let decoded = try TestJSON.decoder.decode(TempUnblockRecord.self, from: data)
    #expect(decoded.domain == record.domain)
    #expect(decoded.uuid == record.uuid)
    #expect(decoded.durationSeconds == record.durationSeconds)
    #expect(decoded.pendingRemoval == record.pendingRemoval)
    #expect(decoded.retryCount == record.retryCount)
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
  }
}
