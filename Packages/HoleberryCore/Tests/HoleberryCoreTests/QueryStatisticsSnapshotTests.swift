import Foundation
import Testing

@testable import HoleberryCore

@Suite("QueryStatisticsSnapshot")
@MainActor
struct QueryStatisticsSnapshotTests {
  private let firstCheck = Date(timeIntervalSince1970: 1_000)
  private let secondCheck = Date(timeIntervalSince1970: 2_000)

  @Test func weightedPercentageUsesCombinedCounts() throws {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let snapshot = makeSnapshot(
      servers: [first, second],
      results: [
        first.id: .success(QuerySummary(totalQueries: 20, totalBlocked: 10)),
        second.id: .success(QuerySummary(totalQueries: 60, totalBlocked: 10))
      ]
    )

    let summary = try #require(snapshot.summary)

    #expect(summary.totalQueries == 80)
    #expect(summary.totalBlocked == 20)
    #expect(summary.blockedPercentage == 25)
    #expect(snapshot.lastCheckedAt == firstCheck)
    #expect(snapshot.availability(at: firstCheck) == .allAvailable)
  }

  @Test func partialFailureAggregatesOnlyTheSuccessfulServer() throws {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let snapshot = makeSnapshot(
      servers: [first, second],
      results: [
        first.id: .success(QuerySummary(totalQueries: 1_000, totalBlocked: 200)),
        second.id: .failure(.unauthorized)
      ]
    )

    let summary = try #require(snapshot.summary)

    #expect(summary.totalQueries == 1_000)
    #expect(summary.totalBlocked == 200)
    #expect(summary.blockedPercentage == 20)
    #expect(snapshot.availability(at: firstCheck) == .someAvailable)
  }

  @Test func totalFailureHasNoSummaryButKeepsTheCheckTime() {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let snapshot = makeSnapshot(
      servers: [first, second],
      results: [first.id: .failure(.network("down")), second.id: .failure(.unauthorized)]
    )

    #expect(snapshot.summary == nil)
    #expect(snapshot.lastCheckedAt == firstCheck)
    #expect(snapshot.availability(at: firstCheck) == .noneAvailable)
  }

  @Test func zeroQuerySuccessIsAValidSummary() throws {
    let server = makeServer()
    let snapshot = makeSnapshot(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 0, totalBlocked: 0))]
    )

    let summary = try #require(snapshot.summary)

    #expect(summary.totalQueries == 0)
    #expect(summary.totalBlocked == 0)
    #expect(summary.blockedPercentage == 0)
  }

  @Test func overflowHasNoSummaryButKeepsSuccessfulAvailability() {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let snapshot = makeSnapshot(
      servers: [first, second],
      results: [
        first.id: .success(QuerySummary(totalQueries: Int.max, totalBlocked: 0)),
        second.id: .success(QuerySummary(totalQueries: 1, totalBlocked: 0))
      ]
    )

    #expect(snapshot.summary == nil)
    #expect(snapshot.lastCheckedAt == firstCheck)
    #expect(snapshot.availability(at: firstCheck) == .allAvailable)
  }

  @Test func failingBatchAfterSuccessDoesNotRetainCounts() {
    let server = makeServer()
    let success = makeSnapshot(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 1_000, totalBlocked: 200))]
    )
    let failure = makeSnapshot(
      servers: [server],
      results: [server.id: .failure(.network("offline"))],
      checkedAt: secondCheck
    )

    #expect(success.summary?.totalQueries == 1_000)
    #expect(failure.summary == nil)
    #expect(failure.lastCheckedAt == secondCheck)
    #expect(failure.availability(at: secondCheck) == .noneAvailable)
  }

  @Test func allScopeKeepsConfiguredOrderAndServerMetadata() {
    let first = ServerConfig(id: UUID(), label: "First", url: "http://first.local", version: .v6)
    let second = ServerConfig(id: UUID(), label: "Second", url: "http://second.local", version: .v5)
    let snapshot = makeSnapshot(
      servers: [first, second],
      results: [
        first.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1)),
        second.id: .success(QuerySummary(totalQueries: 20, totalBlocked: 2))
      ]
    )

    #expect(snapshot.scope == .all)
    #expect(snapshot.servers.map(\.id) == [first.id, second.id])
    #expect(snapshot.servers[0].label == "First")
    #expect(snapshot.servers[0].url == "http://first.local")
    #expect(snapshot.servers[1].version == .v5)
  }

  @Test func singleServerScopeExcludesOtherCountsAndCheckTimes() throws {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let mixed = [
      ServerQueryObservation(
        server: first,
        state: .success(QuerySummary(totalQueries: 10, totalBlocked: 5), checkedAt: firstCheck)
      ),
      ServerQueryObservation(
        server: second,
        state: .success(QuerySummary(totalQueries: 900, totalBlocked: 900), checkedAt: secondCheck)
      )
    ]

    let snapshot = QueryStatisticsSnapshot(
      scope: .server(first.id),
      setupRequired: false,
      observations: mixed
    )

    #expect(snapshot.scope == .server(first.id))
    #expect(snapshot.servers.map(\.id) == [first.id])
    #expect(try #require(snapshot.summary).totalQueries == 10)
    #expect(try #require(snapshot.summary).totalBlocked == 5)
    #expect(snapshot.lastCheckedAt == firstCheck)
    #expect(snapshot.availability(at: firstCheck) == .allAvailable)
  }

  @Test func absentServerScopeProducesAnEmptySnapshot() {
    let configured = makeServer()
    let snapshot = QueryStatisticsSnapshot(
      scope: .server(UUID()),
      setupRequired: false,
      observations: [
        ServerQueryObservation(
          server: configured,
          state: .success(QuerySummary(totalQueries: 10, totalBlocked: 1), checkedAt: firstCheck)
        )
      ]
    )

    #expect(snapshot.servers.isEmpty)
    #expect(snapshot.summary == nil)
    #expect(snapshot.lastCheckedAt == nil)
    #expect(snapshot.availability(at: firstCheck) == .notChecked)
  }

  @Test func noTargetScopeExcludesEveryObservationIncludingTheZeroUUID() {
    let zeroID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    let zero = ServerConfig(id: zeroID, label: "Zero", url: "http://zero.local", version: .v6)
    let snapshot = QueryStatisticsSnapshot(
      scope: .noTarget,
      setupRequired: false,
      observations: [
        ServerQueryObservation(
          server: zero,
          state: .success(QuerySummary(totalQueries: 900, totalBlocked: 300), checkedAt: firstCheck)
        )
      ]
    )

    #expect(snapshot.scope == .noTarget)
    #expect(snapshot.servers.isEmpty)
    #expect(snapshot.summary == nil)
    #expect(snapshot.lastCheckedAt == nil)
    #expect(snapshot.availability(at: firstCheck) == .notChecked)
  }

  @Test func duplicateServerKeepsFirstStateMetadataAndTimestamp() {
    let id = UUID()
    let first = ServerConfig(id: id, label: "First", url: "http://first.local", version: .v6)
    let conflicting = ServerConfig(id: id, label: "Second", url: "http://second.local", version: .v5)
    let snapshot = QueryStatisticsSnapshot(
      scope: .all,
      setupRequired: false,
      observations: [
        ServerQueryObservation(server: first, state: .failure(.network("offline"), checkedAt: firstCheck)),
        ServerQueryObservation(
          server: conflicting,
          state: .success(QuerySummary(totalQueries: 10, totalBlocked: 1), checkedAt: secondCheck)
        )
      ]
    )

    #expect(snapshot.servers.count == 1)
    #expect(snapshot.servers[0].url == "http://first.local")
    #expect(snapshot.servers[0].label == "First")
    #expect(snapshot.servers[0].version == .v6)
    #expect(snapshot.summary == nil)
    #expect(snapshot.lastCheckedAt == firstCheck)
    #expect(snapshot.availability(at: firstCheck) == .noneAvailable)
  }

  @Test func setupRequiredSuppressesSummaryAvailabilityAndCheckTime() {
    let server = makeServer()
    let observations = ServerQueryObservation.make(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1))],
      checkedAt: firstCheck
    )

    let snapshot = QueryStatisticsSnapshot(
      scope: .all,
      setupRequired: true,
      observations: observations
    )

    #expect(snapshot.summary == nil)
    #expect(snapshot.lastCheckedAt == nil)
    #expect(snapshot.availability(at: firstCheck) == .notChecked)
    #expect(snapshot.availability(at: firstCheck.addingTimeInterval(10)) == .notChecked)
  }

  @Test func uncheckedConfigurationChangeHasNoData() {
    let server = makeServer()
    let snapshot = QueryStatisticsSnapshot(
      scope: .all,
      setupRequired: false,
      observations: ServerQueryObservation.make(servers: [server], results: [:], checkedAt: nil)
    )

    #expect(snapshot.servers.count == 1)
    #expect(snapshot.summary == nil)
    #expect(snapshot.lastCheckedAt == nil)
    #expect(snapshot.availability(at: firstCheck) == .notChecked)
  }

  @Test func availabilityExpiresAtExactlySixtyMinutes() throws {
    let server = makeServer()
    let snapshot = makeSnapshot(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1))]
    )

    #expect(snapshot.availability(at: firstCheck.addingTimeInterval(3_599)) == .allAvailable)
    #expect(snapshot.availability(at: firstCheck.addingTimeInterval(3_600)) == .notChecked)
    #expect(try #require(snapshot.summary).totalQueries == 10)
    #expect(snapshot.lastCheckedAt == firstCheck)
  }

  @Test func futureRenderDatesAreNotFresh() throws {
    let server = makeServer()
    let success = makeSnapshot(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1))]
    )
    let failure = makeSnapshot(
      servers: [server],
      results: [server.id: .failure(.network("down"))]
    )
    let beforeTheCheck = firstCheck.addingTimeInterval(-1)

    #expect(success.availability(at: beforeTheCheck) == .notChecked)
    #expect(failure.availability(at: beforeTheCheck) == .notChecked)
    #expect(try #require(success.summary).totalQueries == 10)
    #expect(success.lastCheckedAt == firstCheck)
  }

  @Test func availabilityBoundariesStartAtTheCheckTime() {
    let server = makeServer()
    let success = makeSnapshot(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1))]
    )
    let failure = makeSnapshot(
      servers: [server],
      results: [server.id: .failure(.network("down"))]
    )

    #expect(success.availability(at: firstCheck.addingTimeInterval(-1)) == .notChecked)
    #expect(success.availability(at: firstCheck) == .allAvailable)
    #expect(success.availability(at: firstCheck.addingTimeInterval(3_599)) == .allAvailable)
    #expect(success.availability(at: firstCheck.addingTimeInterval(3_600)) == .notChecked)

    #expect(failure.availability(at: firstCheck.addingTimeInterval(-1)) == .notChecked)
    #expect(failure.availability(at: firstCheck) == .noneAvailable)
    #expect(failure.availability(at: firstCheck.addingTimeInterval(3_599)) == .noneAvailable)
    #expect(failure.availability(at: firstCheck.addingTimeInterval(3_600)) == .notChecked)
  }

  private func makeServer(
    url: String = "http://pihole.local",
    version: ServerVersion = .v6
  ) -> ServerConfig {
    ServerConfig(id: UUID(), url: url, version: version)
  }

  private func makeSnapshot(
    servers: [ServerConfig],
    results: [UUID: Result<QuerySummary, PiholeError>],
    checkedAt: Date? = nil
  ) -> QueryStatisticsSnapshot {
    QueryStatisticsSnapshot(
      scope: .all,
      setupRequired: false,
      observations: ServerQueryObservation.make(
        servers: servers,
        results: results,
        checkedAt: checkedAt ?? firstCheck
      )
    )
  }
}
