import Foundation
import Testing

@testable import HoleberryCore

@Suite("QueryStatisticsFetchResult")
@MainActor
struct QueryStatisticsFetchResultTests {
  @Test func identityIncludesURLAndVersion() {
    let id = UUID()
    let base = QueryStatisticsServer(id: id, url: "http://pihole.local", version: .v6)

    #expect(base != QueryStatisticsServer(id: id, url: "http://other.local", version: .v6))
    #expect(base != QueryStatisticsServer(id: id, url: "http://pihole.local", version: .v5))
    #expect(base == QueryStatisticsServer(id: id, url: "http://pihole.local", version: .v6))
  }

  @Test func weightedPercentageUsesAggregateCounts() throws {
    let first = identity(url: "http://first.local")
    let second = identity(url: "http://second.local")
    let observedAt = Date(timeIntervalSince1970: 1_000)
    let statistics = try #require(
      QueryStatistics(
        servers: [first, second],
        results: [
          first.id: .success(QuerySummary(totalQueries: 20, totalBlocked: 10)),
          second.id: .success(QuerySummary(totalQueries: 60, totalBlocked: 10))
        ],
        observedAt: observedAt
      )
    )

    #expect(statistics.totalQueries == 80)
    #expect(statistics.totalBlocked == 20)
    #expect(statistics.blockedPercentage == 25)
    #expect(statistics.observedAt == observedAt)
  }

  @Test func zeroQueriesProducesZeroPercentage() throws {
    let server = identity()
    let statistics = try #require(
      QueryStatistics(
        servers: [server],
        results: [server.id: .success(QuerySummary(totalQueries: 0, totalBlocked: 0))],
        observedAt: Date(timeIntervalSince1970: 1_000)
      )
    )

    #expect(statistics.totalQueries == 0)
    #expect(statistics.blockedPercentage == 0)
  }

  @Test func emptyConfigurationIsNotChecked() {
    let summary = makeSummary(servers: [], results: [:], checkedAt: Date(timeIntervalSince1970: 1_000))

    #expect(summary.availability == .notChecked)
    #expect(summary.completedStatistics == nil)
  }

  @Test func singleServerSuccessIsAllHealthy() {
    let server = identity()
    let summary = makeSummary(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1))]
    )

    #expect(summary.availability == .allAvailable)
  }

  @Test func singleServerFailureIsNoneHealthy() {
    let server = identity()
    let summary = makeSummary(servers: [server], results: [server.id: .failure(.network("offline"))])

    #expect(summary.availability == .noneAvailable)
  }

  @Test func twoServerHealthMapping() {
    let first = identity(url: "http://first.local")
    let second = identity(url: "http://second.local")
    let success = Result<QuerySummary, PiholeError>.success(
      QuerySummary(totalQueries: 10, totalBlocked: 2)
    )
    let failure = Result<QuerySummary, PiholeError>.failure(.network("offline"))

    let all = makeSummary(servers: [first, second], results: [first.id: success, second.id: success])
    #expect(all.availability == .allAvailable)

    let some = makeSummary(servers: [first, second], results: [first.id: success, second.id: failure])
    #expect(some.availability == .someAvailable)

    let none = makeSummary(servers: [first, second], results: [first.id: failure, second.id: failure])
    #expect(none.availability == .noneAvailable)
  }

  @Test func notCheckedBeforeAnyFetch() {
    let server = identity()
    let summary = makeSummary(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1))],
      checkedAt: nil
    )

    #expect(summary.availability == .notChecked)
  }

  @Test func partialFailureIncludesSuccessfulStatistics() {
    let first = identity(url: "http://first.local")
    let second = identity(url: "http://second.local")
    let summary = makeSummary(
      servers: [first, second],
      results: [
        first.id: .success(QuerySummary(totalQueries: 1_000, totalBlocked: 500)),
        second.id: .failure(.network("offline"))
      ],
      checkedAt: Date(timeIntervalSince1970: 900)
    )

    #expect(summary.availability == .someAvailable)
    #expect(summary.completedStatistics?.totalQueries == 1_000)
    #expect(summary.completedStatistics?.totalBlocked == 500)
    #expect(summary.completedStatistics?.observedAt == Date(timeIntervalSince1970: 900))
  }

  @Test func totalFailureProducesNoStatistics() {
    let first = identity(url: "http://first.local")
    let second = identity(url: "http://second.local")
    let summary = makeSummary(
      servers: [first, second],
      results: [first.id: .failure(.network("offline")), second.id: .failure(.unauthorized)],
      checkedAt: Date(timeIntervalSince1970: 900)
    )

    #expect(summary.availability == .noneAvailable)
    #expect(summary.completedStatistics == nil)
  }

  @Test func missingResultIncludesSuccessfulStatistics() {
    let first = identity(url: "http://first.local")
    let second = identity(url: "http://second.local")
    let summary = makeSummary(
      servers: [first, second],
      results: [first.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1))]
    )

    #expect(summary.completedStatistics?.totalQueries == 10)
    #expect(summary.completedStatistics?.totalBlocked == 1)
  }

  @Test func duplicateServerIdentifiersProduceNoStatistics() {
    let server = identity()
    let summary = makeSummary(
      servers: [server, server],
      results: [server.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1))]
    )

    #expect(summary.completedStatistics == nil)
  }

  @Test func successfulFetchAggregatesOnlyCurrentResults() throws {
    let server = identity()
    let checkedAt = Date(timeIntervalSince1970: 2_000)
    let summary = makeSummary(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 200, totalBlocked: 50))],
      checkedAt: checkedAt
    )
    let statistics = try #require(summary.completedStatistics)

    #expect(statistics.totalQueries == 200)
    #expect(statistics.totalBlocked == 50)
    #expect(statistics.observedAt == checkedAt)
  }

  @Test func blockedFractionClampsToRenderableRange() {
    let observedAt = Date(timeIntervalSince1970: 1_000)

    #expect(
      QueryStatistics(totalQueries: 0, totalBlocked: 0, observedAt: observedAt).blockedFraction == 0
    )
    #expect(
      QueryStatistics(totalQueries: 100, totalBlocked: 25, observedAt: observedAt).blockedFraction == 0.25
    )
    #expect(
      QueryStatistics(totalQueries: 100, totalBlocked: 150, observedAt: observedAt).blockedFraction == 1
    )
    #expect(
      QueryStatistics(totalQueries: 100, totalBlocked: -20, observedAt: observedAt).blockedFraction == 0
    )
  }

  private func identity(
    url: String = "http://pihole.local",
    version: ServerVersion = .v6
  ) -> QueryStatisticsServer {
    QueryStatisticsServer(id: UUID(), url: url, version: version)
  }

  private func makeSummary(
    servers: [QueryStatisticsServer],
    results: [UUID: Result<QuerySummary, PiholeError>],
    checkedAt: Date? = Date(timeIntervalSince1970: 1_000)
  ) -> QueryStatisticsFetchResult {
    QueryStatisticsFetchResult(servers: servers, results: results, checkedAt: checkedAt)
  }
}
