import Foundation
import Testing

@testable import HoleberryCore

@Suite("Unblock Duration Formatter")
struct UnblockDurationFormatterTests {
  @Test(arguments: [
    (10, "10 seconds"),
    (30, "30 seconds"),
    (300, "5 minutes"),
    (60, "1 minute"),
    (3600, "1 hour"),
    (90, "1 minute 30 seconds"),
    (3661, "1 hour 1 minute 1 second"),
    (7200, "2 hours"),
    (0, "0 seconds")
  ])
  func formatsDurations(seconds: TimeInterval, expected: String) {
    #expect(UnblockDurationFormatter.string(from: seconds) == expected)
  }
}
