import Foundation
import Testing
@testable import HoleberryCore

@Suite("TimeInterval convenience", .serialized)
@MainActor
struct TimeIntervalConvenienceTests {
  @Test("hours maps to seconds")
  func hours() {
    #expect(TimeInterval.hours(6) == 21_600)
    #expect(TimeInterval.hours(12) == 43_200)
  }

  @Test("days maps to seconds")
  func days() {
    #expect(TimeInterval.days(1) == 86_400)
    #expect(TimeInterval.days(7) == 604_800)
  }
}
