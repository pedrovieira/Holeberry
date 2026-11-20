import Foundation
import HoleberryCore
import Testing

@Suite("WidgetFooter")
@MainActor
struct WidgetFooterTests {
  private let observedAt = Date(timeIntervalSince1970: 2_000_000)
  private let english = Locale(identifier: "en_US")

  private func rendered(minutesAfterObservation minutes: Int) -> Date {
    observedAt.addingTimeInterval(TimeInterval(minutes) * 60)
  }

  private func text(minutesAfterObservation minutes: Int) -> String {
    WidgetFooter.text(
      observedAt: observedAt,
      renderedAt: rendered(minutesAfterObservation: minutes),
      locale: english
    )
  }

  @Test func footerShowsFoundationRelativeUnits() {
    #expect(text(minutesAfterObservation: 0) == "Updated moments ago")
    #expect(text(minutesAfterObservation: 1) == "Updated 1 min. ago")
    #expect(text(minutesAfterObservation: 59) == "Updated 59 min. ago")
    #expect(text(minutesAfterObservation: 60) == "Updated 1 hr. ago")
  }

  @Test func footerStaysTruthfulSixtyFiveMinutesAfterTheFetch() {
    #expect(text(minutesAfterObservation: 65) == "Updated 1 hr. ago")
    #expect(text(minutesAfterObservation: 119) == "Updated 1 hr. ago")
  }

  @Test func olderObservationsKeepUsingRelativeAges() {
    #expect(text(minutesAfterObservation: 120) == "Updated 2 hr. ago")
    #expect(text(minutesAfterObservation: 6 * 60) == "Updated 6 hr. ago")
    #expect(text(minutesAfterObservation: 3 * 24 * 60) == "Updated 3 days ago")
  }
}

@Suite("WidgetFooter entry schedule")
@MainActor
struct WidgetFooterEntryScheduleTests {
  private let observedAt = Date(timeIntervalSince1970: 2_000_000)
  private let now = Date(timeIntervalSince1970: 2_000_010)

  @Test func scheduleCoversMinutesHoursAndDaysWhenReloadsAreDelayed() {
    let dates = WidgetFooter.entryDates(observedAt: observedAt, now: now)
    let expectedMinutes = (1...60).map { observedAt.addingTimeInterval(TimeInterval($0) * 60) }
    let expectedHours = (2...24).map { observedAt.addingTimeInterval(TimeInterval($0) * 60 * 60) }
    let expectedDays = (2...30).map { observedAt.addingTimeInterval(TimeInterval($0) * 24 * 60 * 60) }
    let expected = expectedMinutes + expectedHours + expectedDays

    #expect(dates == expected)
  }

  @Test func scheduleSkipsDatesThatAlreadyPassed() {
    let lateNow = observedAt.addingTimeInterval(90 * 60)
    let dates = WidgetFooter.entryDates(observedAt: observedAt, now: lateNow)

    #expect(dates.first == observedAt.addingTimeInterval(2 * 60 * 60))
    #expect(dates.allSatisfy { $0 > lateNow })
  }

  @Test func anUncheckedWidgetHasNoEntries() {
    #expect(WidgetFooter.entryDates(observedAt: nil, now: now).isEmpty)
  }
}
