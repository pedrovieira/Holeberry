import Foundation
import Testing

@testable import HoleberryCore

@Suite("Relative age formatting")
@MainActor
struct RelativeAgeFormatterTests {
  private let now = Date(timeIntervalSince1970: 2_000)
  private let english = Locale(identifier: "en_US")

  private func date(secondsAgo: TimeInterval) -> Date {
    now.addingTimeInterval(-secondsAgo)
  }

  @Test func standardUsesAbbreviatedLocalizedUnits() {
    let formatter = RelativeAgeFormatter(locale: english)

    #expect(formatter.string(since: date(secondsAgo: 10), relativeTo: now) == "10 sec. ago")
    #expect(formatter.string(since: date(secondsAgo: 90), relativeTo: now) == "1 min. ago")
    #expect(formatter.string(since: date(secondsAgo: 3_900), relativeTo: now) == "1 hr. ago")
  }

  @Test func standardWithMomentsReplacesTheFirstMinute() {
    let formatter = RelativeAgeFormatter(style: .standardWithMoments, locale: english)

    #expect(formatter.string(since: date(secondsAgo: 59), relativeTo: now) == "moments ago")
    #expect(formatter.string(since: date(secondsAgo: 60), relativeTo: now) == "1 min. ago")
  }

  @Test func wholeMinutesFloorsAtOneMinute() {
    let formatter = RelativeAgeFormatter(style: .wholeMinutes, locale: english)

    #expect(formatter.string(since: date(secondsAgo: 10), relativeTo: now) == "1 min. ago")
    #expect(formatter.string(since: date(secondsAgo: 125), relativeTo: now) == "2 min. ago")
    #expect(formatter.string(since: date(secondsAgo: 3_900), relativeTo: now) == "1 hr. ago")
  }

  @Test func differentlyConfiguredLocalesKeepTheirOwnSettings() {
    let plain = RelativeAgeFormatter(locale: english)
    let arabicDigits = RelativeAgeFormatter(locale: Locale(identifier: "en_US@numbers=arab"))

    for _ in 0..<3 {
      let plainText = plain.string(since: date(secondsAgo: 90), relativeTo: now)
      let arabicText = arabicDigits.string(since: date(secondsAgo: 90), relativeTo: now)

      #expect(plainText == "1 min. ago")
      #expect(arabicText != plainText)
      #expect(arabicText.hasSuffix(" min. ago"))
    }
  }

  @Test func concurrentCallsProduceConsistentText() async {
    let formatter = RelativeAgeFormatter(locale: Locale(identifier: "en_ZA"))
    let target = date(secondsAgo: 3_900)
    let reference = now
    let expected = formatter.string(since: target, relativeTo: reference)

    let results = await withTaskGroup(of: String.self) { group in
      for _ in 0..<32 {
        group.addTask {
          formatter.string(since: target, relativeTo: reference)
        }
      }
      var collected: [String] = []
      for await result in group {
        collected.append(result)
      }
      return collected
    }

    #expect(Set(results) == [expected])
  }
}
