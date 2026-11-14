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

    #expect(formatter.string(since: date(secondsAgo: 59), relativeTo: now) == "a few moments ago")
    #expect(formatter.string(since: date(secondsAgo: 60), relativeTo: now) == "1 min. ago")
  }

  @Test func wholeMinutesFloorsAtOneMinute() {
    let formatter = RelativeAgeFormatter(style: .wholeMinutes, locale: english)

    #expect(formatter.string(since: date(secondsAgo: 10), relativeTo: now) == "1 min. ago")
    #expect(formatter.string(since: date(secondsAgo: 125), relativeTo: now) == "2 min. ago")
    #expect(formatter.string(since: date(secondsAgo: 3_900), relativeTo: now) == "1 hr. ago")
  }

  @Test func compactShowsMomentsDuringTheFirstMinute() {
    let formatter = RelativeAgeFormatter(style: .compact, locale: english)

    #expect(formatter.string(since: date(secondsAgo: -1), relativeTo: now) == "moments ago")
    #expect(formatter.string(since: date(secondsAgo: 0), relativeTo: now) == "moments ago")
    #expect(formatter.string(since: date(secondsAgo: 59.999), relativeTo: now) == "moments ago")
  }

  @Test func compactShowsWholeMinutesWithoutSeconds() {
    let formatter = RelativeAgeFormatter(style: .compact, locale: english)

    #expect(formatter.string(since: date(secondsAgo: 60), relativeTo: now) == "1min ago")
    #expect(formatter.string(since: date(secondsAgo: 119.999), relativeTo: now) == "1min ago")
    #expect(formatter.string(since: date(secondsAgo: 120), relativeTo: now) == "2min ago")
    #expect(formatter.string(since: date(secondsAgo: 3_599), relativeTo: now) == "59min ago")
  }

  @Test func compactShowsHoursAndDays() {
    let formatter = RelativeAgeFormatter(style: .compact, locale: english)

    #expect(formatter.string(since: date(secondsAgo: 3_600), relativeTo: now) == "1h ago")
    #expect(formatter.string(since: date(secondsAgo: 7_199), relativeTo: now) == "1h ago")
    #expect(formatter.string(since: date(secondsAgo: 7_200), relativeTo: now) == "2h ago")
    #expect(formatter.string(since: date(secondsAgo: 86_399), relativeTo: now) == "23h ago")
    #expect(formatter.string(since: date(secondsAgo: 86_400), relativeTo: now) == "1d ago")
    #expect(formatter.string(since: date(secondsAgo: 172_800), relativeTo: now) == "2d ago")
  }
}
