import Foundation
import HoleberryCore
import Testing

@Suite("WidgetPresentation")
@MainActor
struct WidgetPresentationTests {
  @Test func successfulFetchShowsLiveStatistics() {
    let server = makeServer()
    let checkedAt = Date(timeIntervalSince1970: 2_000)
    let summary = QueryStatisticsFetchResult(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 200, totalBlocked: 50))],
      checkedAt: checkedAt
    )

    let presentation = WidgetPresentation(summary: summary, now: checkedAt.addingTimeInterval(10))

    #expect(presentation.availability == .allAvailable)
    #expect(
      presentation.content
        == .statistics(
          QueryStatistics(totalQueries: 200, totalBlocked: 50, observedAt: checkedAt)))
    #expect(presentation.statistics?.totalQueries == 200)
    #expect(presentation.statistics?.totalBlocked == 50)
    #expect(presentation.statistics?.observedAt == checkedAt)
    #expect(presentation.lastCheckedAt == checkedAt)
  }

  @Test func partialFailureShowsHealthyServerStatistics() {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let summary = QueryStatisticsFetchResult(
      servers: [first, second],
      results: [
        first.id: .success(QuerySummary(totalQueries: 1_000, totalBlocked: 500)),
        second.id: .failure(.network("down"))
      ],
      checkedAt: Date(timeIntervalSince1970: 2_000)
    )

    let presentation = WidgetPresentation(summary: summary, now: Date(timeIntervalSince1970: 2_010))

    #expect(presentation.availability == .someAvailable)
    #expect(presentation.statistics?.totalQueries == 1_000)
    #expect(presentation.statistics?.totalBlocked == 500)
    #expect(presentation.statistics?.blockedPercentage == 50)
  }

  @Test func totalFailureIsUnavailable() {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let summary = QueryStatisticsFetchResult(
      servers: [first, second],
      results: [first.id: .failure(.network("down")), second.id: .failure(.unauthorized)],
      checkedAt: Date(timeIntervalSince1970: 2_000)
    )

    let presentation = WidgetPresentation(summary: summary, now: Date(timeIntervalSince1970: 2_010))

    #expect(presentation.availability == .noneAvailable)
    #expect(presentation.content == .unavailable)
    #expect(presentation.statistics == nil)
  }

  @Test func zeroQueriesShowsZeroPercentStatistics() {
    let server = makeServer()
    let checkedAt = Date(timeIntervalSince1970: 2_000)
    let summary = QueryStatisticsFetchResult(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 0, totalBlocked: 0))],
      checkedAt: checkedAt
    )

    let presentation = WidgetPresentation(summary: summary, now: checkedAt.addingTimeInterval(10))

    #expect(presentation.statistics?.blockedPercentage == 0)
    #expect(presentation.statistics?.totalQueries == 0)
  }

  @Test func availabilityExpiresSixtyMinutesAfterLatestCheck() {
    let server = makeServer()
    let checkedAt = Date(timeIntervalSince1970: 2_000)
    let success = QueryStatisticsFetchResult(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1))],
      checkedAt: checkedAt
    )
    let failure = QueryStatisticsFetchResult(
      servers: [server],
      results: [server.id: .failure(.network("down"))],
      checkedAt: checkedAt
    )

    #expect(
      WidgetPresentation(summary: success, now: checkedAt.addingTimeInterval(3_599)).availability == .allAvailable)
    #expect(WidgetPresentation(summary: success, now: checkedAt.addingTimeInterval(3_600)).availability == .notChecked)
    #expect(
      WidgetPresentation(summary: failure, now: checkedAt.addingTimeInterval(3_599)).availability == .noneAvailable)
    #expect(WidgetPresentation(summary: failure, now: checkedAt.addingTimeInterval(3_600)).availability == .notChecked)
  }

  @Test func noCurrentCheckIsUnavailable() {
    let server = makeServer()
    let summary = QueryStatisticsFetchResult(servers: [server], results: [:], checkedAt: nil)

    let presentation = WidgetPresentation(summary: summary, now: Date(timeIntervalSince1970: 1_000))

    #expect(presentation.availability == .notChecked)
    #expect(presentation.content == .unavailable)
    #expect(presentation.statistics == nil)
    #expect(presentation.lastCheckedAt == nil)
  }

  @Test func emptyConfigurationIsNoServers() {
    let summary = QueryStatisticsFetchResult(servers: [], results: [:], checkedAt: Date())

    let presentation = WidgetPresentation(summary: summary, now: Date())

    #expect(presentation.content == .noServers)
    #expect(presentation.availability == .notChecked)
  }

  @Test func setupRequiredIsGrayAndEmpty() {
    #expect(WidgetPresentation.setupRequired.content == .setupRequired)
    #expect(WidgetPresentation.setupRequired.availability == .notChecked)
    #expect(WidgetPresentation.setupRequired.statistics == nil)
    #expect(WidgetPresentation.setupRequired.lastCheckedAt == nil)
  }

  private func makeServer(url: String = "http://pihole.local") -> ServerConfig {
    ServerConfig(id: UUID(), url: url, version: .v6)
  }
}
