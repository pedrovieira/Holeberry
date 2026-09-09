import Foundation
import HoleberryCore
import Testing

@Suite("GravityUpdateCadence", .serialized)
@MainActor
struct GravityUpdateCadenceTests {
  @Test("intervalSeconds maps each case; nil for never")
  func intervals() {
    #expect(GravityUpdateCadence.every6Hours.intervalSeconds == TimeInterval(6 * 3600))
    #expect(GravityUpdateCadence.every12Hours.intervalSeconds == TimeInterval(12 * 3600))
    #expect(GravityUpdateCadence.daily.intervalSeconds == TimeInterval(24 * 3600))
    #expect(GravityUpdateCadence.weekly.intervalSeconds == TimeInterval(7 * 24 * 3600))
    #expect(GravityUpdateCadence.never.intervalSeconds == nil)
  }

  @Test("Codable round-trip preserves raw values")
  func codableRoundTrip() throws {
    for cadence in GravityUpdateCadence.allCases {
      let data = try JSONEncoder().encode(cadence)
      let decoded = try JSONDecoder().decode(GravityUpdateCadence.self, from: data)
      #expect(decoded == cadence)
    }
  }
}
