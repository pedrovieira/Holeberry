import Foundation
import HoleberryCore
import Testing

@Suite("QueryStatisticsEntry")
@MainActor
struct QueryStatisticsEntryTests {
  private let checkedAt = Date(timeIntervalSince1970: 2_000)

  @Test func setupRequiredSuppressesSummaryAvailabilityAndCheckTime() {
    let server = makeServer()
    let entry = QueryStatisticsEntry(
      date: checkedAt,
      base: snapshot(
        servers: [server],
        results: [server.id: .success(QuerySummary(totalQueries: 200, totalBlocked: 50))],
        setupRequired: true
      )
    )

    #expect(entry.content == .setupRequired)
    #expect(entry.statusText == "All servers")
    #expect(entry.summary == nil)
    #expect(entry.lastCheckedAt == nil)
    #expect(entry.availability == .notChecked)
  }

  @Test func emptyConfigurationShowsNoServers() {
    let entry = QueryStatisticsEntry(
      date: checkedAt,
      base: QueryStatisticsSnapshot(scope: .all, setupRequired: false, observations: [])
    )

    #expect(entry.content == .noServers)
    #expect(entry.summary == nil)
    #expect(entry.lastCheckedAt == nil)
    #expect(entry.availability == .notChecked)
  }

  @Test func successfulBatchShowsLiveStatistics() throws {
    let server = makeServer()
    let entry = QueryStatisticsEntry(
      date: checkedAt.addingTimeInterval(10),
      base: snapshot(
        servers: [server],
        results: [server.id: .success(QuerySummary(totalQueries: 200, totalBlocked: 50))]
      )
    )

    #expect(entry.content == .statistics)
    #expect(entry.availability == .allAvailable)
    #expect(entry.statusText == "All servers online")
    #expect(entry.lastCheckedAt == checkedAt)
    let summary = try #require(entry.summary)
    #expect(summary.totalQueries == 200)
    #expect(summary.totalBlocked == 50)
    #expect(summary.blockedPercentage == 25)
  }

  @Test func partialFailureShowsOnlyTheHealthyServerCounts() throws {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let entry = QueryStatisticsEntry(
      date: checkedAt.addingTimeInterval(10),
      base: snapshot(
        servers: [first, second],
        results: [
          first.id: .success(QuerySummary(totalQueries: 1_000, totalBlocked: 500)),
          second.id: .failure(.unauthorized)
        ]
      )
    )

    #expect(entry.content == .statistics)
    #expect(entry.availability == .someAvailable)
    #expect(entry.statusText == "Some servers unavailable")
    let summary = try #require(entry.summary)
    #expect(summary.totalQueries == 1_000)
    #expect(summary.totalBlocked == 500)
    #expect(summary.blockedPercentage == 50)
  }

  @Test func totalFailureShowsUnavailable() {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let entry = QueryStatisticsEntry(
      date: checkedAt.addingTimeInterval(10),
      base: snapshot(
        servers: [first, second],
        results: [first.id: .failure(.network("down")), second.id: .failure(.unauthorized)]
      )
    )

    #expect(entry.content == .unavailable)
    #expect(entry.availability == .noneAvailable)
    #expect(entry.statusText == "All servers unavailable")
    #expect(entry.summary == nil)
    #expect(entry.lastCheckedAt == checkedAt)
  }

  @Test func zeroQueriesShowZeroedStatistics() throws {
    let server = makeServer()
    let entry = QueryStatisticsEntry(
      date: checkedAt.addingTimeInterval(10),
      base: snapshot(
        servers: [server],
        results: [server.id: .success(QuerySummary(totalQueries: 0, totalBlocked: 0))]
      )
    )

    #expect(entry.content == .statistics)
    let summary = try #require(entry.summary)
    #expect(summary.totalQueries == 0)
    #expect(summary.totalBlocked == 0)
    #expect(summary.blockedPercentage == 0)
  }

  @Test func unavailableServersKeepTheirTypedFailure() throws {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let entry = QueryStatisticsEntry(
      date: checkedAt,
      base: snapshot(
        servers: [first, second],
        results: [
          first.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1)),
          second.id: .failure(.missingCredential)
        ]
      )
    )

    let unavailable = try #require(entry.base.observations.last)
    #expect(unavailable.server == second)
    #expect(unavailable.state == .failure(.missingCredential, checkedAt: checkedAt))
  }

  @Test func failingBatchAfterSuccessRetainsNoCounts() throws {
    let server = makeServer()
    let success = QueryStatisticsEntry(
      date: checkedAt,
      base: snapshot(
        servers: [server],
        results: [server.id: .success(QuerySummary(totalQueries: 1_000, totalBlocked: 200))]
      )
    )
    #expect(try #require(success.summary).totalQueries == 1_000)

    let laterCheck = checkedAt.addingTimeInterval(15 * 60)
    let failure = QueryStatisticsEntry(
      date: laterCheck,
      base: snapshot(
        servers: [server],
        results: [server.id: .failure(.network("offline"))],
        checkedAt: laterCheck
      )
    )

    #expect(failure.summary == nil)
    #expect(failure.content == .unavailable)
    #expect(failure.availability == .noneAvailable)
    #expect(failure.lastCheckedAt == laterCheck)
  }

  @Test func configurationChangeHasNoOldObservations() {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let entry = QueryStatisticsEntry(
      date: checkedAt,
      base: QueryStatisticsSnapshot(
        scope: .all,
        setupRequired: false,
        observations: ServerQueryObservation.make(
          servers: [first, second],
          results: [
            first.id: .success(QuerySummary(totalQueries: 100, totalBlocked: 10)),
            second.id: .success(QuerySummary(totalQueries: 100, totalBlocked: 10))
          ],
          checkedAt: nil
        )
      )
    )

    #expect(entry.base.observations.map(\.state) == [.notChecked, .notChecked])
    #expect(entry.content == .unavailable)
    #expect(entry.availability == .notChecked)
    #expect(entry.lastCheckedAt == nil)
    #expect(entry.statusText == "All servers")
  }

  @Test func footerOnlyEntriesPreserveTheBaseAndCheckTime() throws {
    let server = makeServer()
    let base = snapshot(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 300, totalBlocked: 30))]
    )
    let firstRender = QueryStatisticsEntry(date: checkedAt, base: base)
    let laterRender = QueryStatisticsEntry(date: checkedAt.addingTimeInterval(30 * 60), base: base)

    #expect(laterRender.base == firstRender.base)
    #expect(laterRender.lastCheckedAt == checkedAt)
    #expect(laterRender.date == checkedAt.addingTimeInterval(30 * 60))
    #expect(laterRender.availability == .allAvailable)
    let summary = try #require(laterRender.summary)
    #expect(summary.totalQueries == 300)
    #expect(summary.blockedPercentage == 10)
  }

  @Test func availabilityExpiresAtExactlySixtyMinutes() throws {
    let server = makeServer()
    let base = snapshot(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1))]
    )

    let justInside = QueryStatisticsEntry(date: checkedAt.addingTimeInterval(3_599), base: base)
    #expect(justInside.availability == .allAvailable)

    let atBoundary = QueryStatisticsEntry(date: checkedAt.addingTimeInterval(3_600), base: base)
    #expect(atBoundary.availability == .notChecked)
    #expect(atBoundary.content == .statistics)
    #expect(atBoundary.lastCheckedAt == checkedAt)
    #expect(try #require(atBoundary.summary).totalQueries == 10)
  }

  @Test func expiredFailureBatchBecomesNotChecked() {
    let server = makeServer()
    let entry = QueryStatisticsEntry(
      date: checkedAt.addingTimeInterval(3_600),
      base: snapshot(
        servers: [server],
        results: [server.id: .failure(.network("down"))]
      )
    )

    #expect(entry.availability == .notChecked)
    #expect(entry.content == .unavailable)
    #expect(entry.lastCheckedAt == checkedAt)
  }

  @Test func futureRenderDatesAreNotFresh() throws {
    let server = makeServer()
    let base = snapshot(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1))]
    )
    let entry = QueryStatisticsEntry(date: checkedAt.addingTimeInterval(-1), base: base)

    #expect(entry.availability == .notChecked)
    #expect(entry.content == .statistics)
    #expect(entry.lastCheckedAt == checkedAt)
    #expect(try #require(entry.summary).totalQueries == 10)
  }

  @Test func placeholderShowsSetupAndStatisticsPreviews() throws {
    let placeholder = QueryStatisticsEntry.placeholder(now: checkedAt)
    #expect(placeholder.content == .statistics)
    #expect(placeholder.availability == .allAvailable)
    #expect(try #require(placeholder.summary).totalQueries == 184_200)
    #expect(placeholder.base.scope == .all)

    let scopedID = UUID()
    let scoped = QueryStatisticsEntry.placeholder(now: checkedAt, scope: .server(scopedID))
    #expect(scoped.base.scope == .server(scopedID))
    #expect(scoped.base.servers.map(\.id) == [scopedID])
    #expect(scoped.content == .statistics)

    let setup = QueryStatisticsEntry.setupRequired(now: checkedAt)
    #expect(setup.content == .setupRequired)
    #expect(setup.base.observations.isEmpty)
  }

  @Test func additionalEntryReceivesSharedDisplayBehavior() throws {
    let server = makeServer()
    let base = snapshot(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 400, totalBlocked: 100))]
    )
    let entry = FutureHistoryTestEntry(date: checkedAt.addingTimeInterval(60), base: base, historyNote: "7 buckets")

    let shared = sharedPresentation(of: entry)

    #expect(shared.content == .statistics)
    #expect(shared.statusText == "All servers online")
    #expect(shared.availability == .allAvailable)
    #expect(shared.lastCheckedAt == checkedAt)
    #expect(try #require(shared.summary).blockedPercentage == 25)
    #expect(entry.historyNote == "7 buckets")
  }

  @Test func additionalEntrySharesFreshnessRulesForLaterRenderDates() {
    let server = makeServer()
    let base = snapshot(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 40, totalBlocked: 4))]
    )
    let fresh = FutureHistoryTestEntry(date: checkedAt.addingTimeInterval(3_599), base: base, historyNote: "fresh")
    let expired = FutureHistoryTestEntry(date: checkedAt.addingTimeInterval(3_600), base: base, historyNote: "expired")

    #expect(sharedPresentation(of: fresh).availability == .allAvailable)
    #expect(sharedPresentation(of: expired).availability == .notChecked)
    #expect(sharedPresentation(of: expired).content == .statistics)
    #expect(sharedPresentation(of: expired).lastCheckedAt == checkedAt)
  }

  private func makeServer(
    url: String = "http://pihole.local",
    version: ServerVersion = .v6
  ) -> ServerConfig {
    ServerConfig(id: UUID(), url: url, version: version)
  }

  private func snapshot(
    servers: [ServerConfig],
    results: [UUID: Result<QuerySummary, PiholeError>],
    checkedAt: Date? = nil,
    scope: ServerScope = .all,
    setupRequired: Bool = false
  ) -> QueryStatisticsSnapshot {
    QueryStatisticsSnapshot(
      scope: scope,
      setupRequired: setupRequired,
      observations: ServerQueryObservation.make(
        servers: servers,
        results: results,
        checkedAt: checkedAt ?? self.checkedAt
      )
    )
  }

  private func sharedPresentation<E: ServerWidgetEntry>(of entry: E) -> (
    content: ServerWidgetContent,
    statusText: String,
    summary: QuerySummary?,
    lastCheckedAt: Date?,
    availability: QueryStatisticsAvailability
  ) {
    (entry.content, entry.statusText, entry.summary, entry.lastCheckedAt, entry.availability)
  }
}

/// Test-only extra payload using the shared entry defaults.
private struct FutureHistoryTestEntry: ServerWidgetEntry {
  let date: Date
  let base: QueryStatisticsSnapshot
  let historyNote: String
}
