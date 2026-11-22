import Foundation
import Testing

@testable import HoleberryCore

@Suite("ServerQueryObservation construction")
@MainActor
struct ServerQueryObservationConstructionTests {
  @Test func completedFetchBuildsObservationsInConfiguredServerOrder() {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let checkedAt = Date(timeIntervalSince1970: 1_000)

    let observations = ServerQueryObservation.make(
      servers: [first, second],
      results: [
        second.id: .success(QuerySummary(totalQueries: 60, totalBlocked: 10)),
        first.id: .failure(.network("offline"))
      ],
      checkedAt: checkedAt
    )

    #expect(observations.map(\.server) == [first, second])
    #expect(observations.first?.state == .failure(.network("offline"), checkedAt: checkedAt))
    #expect(
      observations.last?.state
        == .success(QuerySummary(totalQueries: 60, totalBlocked: 10), checkedAt: checkedAt)
    )
  }

  @Test func missingCompletedResultIsAnExplicitFailure() throws {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let checkedAt = Date(timeIntervalSince1970: 1_000)

    let observations = ServerQueryObservation.make(
      servers: [first, second],
      results: [first.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1))],
      checkedAt: checkedAt
    )

    let missing = try #require(observations.last)
    #expect(missing.server == second)
    #expect(missing.state == .failure(.unknown("Missing query summary result"), checkedAt: checkedAt))
    #expect(ServerQueryObservation.availability(in: observations) == .someAvailable)
  }

  @Test func resultsOutsideTheConfigurationSnapshotAreIgnored() throws {
    let configured = makeServer(url: "http://configured.local")
    let stray = makeServer(url: "http://stray.local")
    let checkedAt = Date(timeIntervalSince1970: 1_000)

    let observations = ServerQueryObservation.make(
      servers: [configured],
      results: [
        configured.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1)),
        stray.id: .success(QuerySummary(totalQueries: 9_000, totalBlocked: 9_000))
      ],
      checkedAt: checkedAt
    )

    #expect(observations.count == 1)
    #expect(observations.first?.server == configured)
    let aggregate = try #require(ServerQueryObservation.aggregate(observations))
    #expect(aggregate.totalQueries == 10)
    #expect(aggregate.totalBlocked == 1)
    #expect(ServerQueryObservation.availability(in: observations) == .allAvailable)
  }

  @Test func duplicateServerConfigurationKeepsTheFirstOccurrence() throws {
    let id = UUID()
    let first = ServerConfig(id: id, url: "http://first.local", version: .v6)
    let conflicting = ServerConfig(id: id, label: "Second", url: "http://second.local", version: .v5)
    let checkedAt = Date(timeIntervalSince1970: 1_000)

    let observations = ServerQueryObservation.make(
      servers: [first, conflicting],
      results: [id: .success(QuerySummary(totalQueries: 4, totalBlocked: 2))],
      checkedAt: checkedAt
    )

    #expect(observations.count == 1)
    let observation = try #require(observations.first)
    #expect(observation.server.url == "http://first.local")
    #expect(observation.server.version == .v6)
    let aggregate = try #require(ServerQueryObservation.aggregate(observations))
    #expect(aggregate.totalQueries == 4)
  }

  @Test func duplicatesInObservationInputsCountOnce() throws {
    let server = makeServer()
    let checkedAt = Date(timeIntervalSince1970: 1_000)
    let observation = ServerQueryObservation(
      server: server,
      state: .success(QuerySummary(totalQueries: 10, totalBlocked: 1), checkedAt: checkedAt)
    )

    let aggregate = try #require(ServerQueryObservation.aggregate([observation, observation]))
    #expect(aggregate.totalQueries == 10)
    #expect(aggregate.totalBlocked == 1)
    #expect(ServerQueryObservation.availability(in: [observation, observation]) == .allAvailable)
  }

  @Test func uncheckedBatchHasNoValuesRegardlessOfResults() {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")

    let observations = ServerQueryObservation.make(
      servers: [first, second],
      results: [
        first.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1)),
        second.id: .failure(.network("offline"))
      ],
      checkedAt: nil
    )

    #expect(observations.map(\.state) == [.notChecked, .notChecked])
    #expect(observations.allSatisfy { $0.checkedAt == nil })
    #expect(ServerQueryObservation.aggregate(observations) == nil)
    #expect(ServerQueryObservation.availability(in: observations) == .notChecked)
  }

  @Test func emptyConfigurationHasNoObservations() {
    let observations = ServerQueryObservation.make(
      servers: [],
      results: [:],
      checkedAt: Date(timeIntervalSince1970: 1_000)
    )

    #expect(observations.isEmpty)
    #expect(ServerQueryObservation.aggregate(observations) == nil)
    #expect(ServerQueryObservation.availability(in: observations) == .notChecked)
  }

  @Test func successObservationKeepsItsQuerySummaryAndGravityTimestamp() throws {
    let server = makeServer()
    let checkedAt = Date(timeIntervalSince1970: 1_000)
    let gravity = Date(timeIntervalSince1970: 900)
    let summary = QuerySummary(totalQueries: 10, totalBlocked: 5, gravityLastUpdated: gravity)

    let observations = ServerQueryObservation.make(
      servers: [server],
      results: [server.id: .success(summary)],
      checkedAt: checkedAt
    )

    let observation = try #require(observations.first)
    #expect(observation.state == .success(summary, checkedAt: checkedAt))
    #expect(observation.checkedAt == checkedAt)
    if case .success(let retained, _) = observation.state {
      #expect(retained.gravityLastUpdated == gravity)
    } else {
      Issue.record("Expected a successful observation")
    }
  }

  private func makeServer(
    url: String = "http://pihole.local",
    version: ServerVersion = .v6
  ) -> ServerConfig {
    ServerConfig(id: UUID(), url: url, version: version)
  }
}

@Suite("ServerQueryObservation aggregation")
@MainActor
struct ServerQueryObservationAggregationTests {
  @Test func weightedPercentageUsesCombinedCounts() throws {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let observations = makeObservations(
      servers: [first, second],
      results: [
        first.id: .success(QuerySummary(totalQueries: 20, totalBlocked: 10)),
        second.id: .success(QuerySummary(totalQueries: 60, totalBlocked: 10))
      ]
    )

    let aggregate = try #require(ServerQueryObservation.aggregate(observations))

    #expect(aggregate.totalQueries == 80)
    #expect(aggregate.totalBlocked == 20)
    #expect(aggregate.blockedPercentage == 25)
  }

  @Test func failedServerContributesNothingToTheCurrentAggregate() throws {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let observations = makeObservations(
      servers: [first, second],
      results: [
        first.id: .success(QuerySummary(totalQueries: 1_000, totalBlocked: 200)),
        second.id: .failure(.unauthorized)
      ]
    )

    let aggregate = try #require(ServerQueryObservation.aggregate(observations))

    #expect(aggregate.totalQueries == 1_000)
    #expect(aggregate.totalBlocked == 200)
    #expect(aggregate.blockedPercentage == 20)
    #expect(ServerQueryObservation.availability(in: observations) == .someAvailable)
  }

  @Test func previousSuccessIsNotRetainedByAFailingFetch() {
    let server = makeServer()
    let success = makeObservations(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 1_000, totalBlocked: 200))]
    )
    let failure = makeObservations(
      servers: [server],
      results: [server.id: .failure(.network("offline"))]
    )

    #expect(ServerQueryObservation.aggregate(success)?.totalQueries == 1_000)
    #expect(ServerQueryObservation.aggregate(failure) == nil)
    #expect(ServerQueryObservation.availability(in: failure) == .noneAvailable)
  }

  @Test func noSuccessfulObservationsProduceNoAggregate() {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let observations = makeObservations(
      servers: [first, second],
      results: [first.id: .failure(.network("offline")), second.id: .failure(.unauthorized)]
    )

    #expect(ServerQueryObservation.aggregate(observations) == nil)
    #expect(ServerQueryObservation.availability(in: observations) == .noneAvailable)
  }

  @Test func zeroQuerySuccessProducesAZeroValuedSummary() throws {
    let server = makeServer()
    let observations = makeObservations(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 0, totalBlocked: 0))]
    )

    let aggregate = try #require(ServerQueryObservation.aggregate(observations))

    #expect(aggregate.totalQueries == 0)
    #expect(aggregate.totalBlocked == 0)
    #expect(aggregate.blockedPercentage == 0)
    #expect(ServerQueryObservation.availability(in: observations) == .allAvailable)
  }

  @Test func aggregateClearsOnlyTheCombinedGravityTimestamp() throws {
    let server = makeServer()
    let gravity = Date(timeIntervalSince1970: 900)
    let observations = makeObservations(
      servers: [server],
      results: [server.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1, gravityLastUpdated: gravity))]
    )

    let aggregate = try #require(ServerQueryObservation.aggregate(observations))

    #expect(aggregate.gravityLastUpdated == nil)
    if case .success(let retained, _) = observations[0].state {
      #expect(retained.gravityLastUpdated == gravity)
    } else {
      Issue.record("Expected a successful observation")
    }
  }

  @Test func int32MaxCountsFromTwoServersAddExactly() throws {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let maximum = Int(Int32.max)
    let observations = makeObservations(
      servers: [first, second],
      results: [
        first.id: .success(QuerySummary(totalQueries: maximum, totalBlocked: maximum)),
        second.id: .success(QuerySummary(totalQueries: maximum, totalBlocked: maximum))
      ]
    )

    let aggregate = try #require(ServerQueryObservation.aggregate(observations))

    #expect(aggregate.totalQueries == 4_294_967_294)
    #expect(aggregate.totalBlocked == 4_294_967_294)
  }

  @Test func queryCountOverflowProducesNoAggregateButKeepsAvailability() {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let observations = makeObservations(
      servers: [first, second],
      results: [
        first.id: .success(QuerySummary(totalQueries: Int.max, totalBlocked: 1)),
        second.id: .success(QuerySummary(totalQueries: 1, totalBlocked: 1))
      ]
    )

    #expect(ServerQueryObservation.aggregate(observations) == nil)
    #expect(ServerQueryObservation.availability(in: observations) == .allAvailable)
  }

  @Test func blockedCountOverflowProducesNoAggregateButKeepsAvailability() {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let observations = makeObservations(
      servers: [first, second],
      results: [
        first.id: .success(QuerySummary(totalQueries: 1, totalBlocked: Int.max)),
        second.id: .success(QuerySummary(totalQueries: 1, totalBlocked: 1))
      ]
    )

    #expect(ServerQueryObservation.aggregate(observations) == nil)
    #expect(ServerQueryObservation.availability(in: observations) == .allAvailable)
  }

  @Test func querySummaryPercentageIsWeightedAndSafeAtZero() {
    #expect(QuerySummary(totalQueries: 200, totalBlocked: 50).blockedPercentage == 25)
    #expect(QuerySummary(totalQueries: 0, totalBlocked: 0).blockedPercentage == 0)
  }

  private func makeServer(
    url: String = "http://pihole.local",
    version: ServerVersion = .v6
  ) -> ServerConfig {
    ServerConfig(id: UUID(), url: url, version: version)
  }

  private func makeObservations(
    servers: [ServerConfig],
    results: [UUID: Result<QuerySummary, PiholeError>],
    checkedAt: Date? = Date(timeIntervalSince1970: 1_000)
  ) -> [ServerQueryObservation] {
    ServerQueryObservation.make(servers: servers, results: results, checkedAt: checkedAt)
  }
}

@Suite("ServerQueryObservation availability")
@MainActor
struct ServerQueryObservationAvailabilityTests {
  @Test func successAndFailureMappingCountsDistinctServers() {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let success = Result<QuerySummary, PiholeError>.success(QuerySummary(totalQueries: 10, totalBlocked: 2))
    let failure = Result<QuerySummary, PiholeError>.failure(.network("offline"))

    let all = makeObservations(servers: [first, second], results: [first.id: success, second.id: success])
    #expect(ServerQueryObservation.availability(in: all) == .allAvailable)

    let some = makeObservations(servers: [first, second], results: [first.id: success, second.id: failure])
    #expect(ServerQueryObservation.availability(in: some) == .someAvailable)

    let none = makeObservations(servers: [first, second], results: [first.id: failure, second.id: failure])
    #expect(ServerQueryObservation.availability(in: none) == .noneAvailable)

    let unchecked = makeObservations(
      servers: [first, second],
      results: [first.id: success, second.id: failure],
      checkedAt: nil
    )
    #expect(ServerQueryObservation.availability(in: unchecked) == .notChecked)
  }

  @Test func availabilityFollowsQuerySummaryResultsNotObservationArithmetic() {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let checkedAt = Date(timeIntervalSince1970: 1_000)
    let observations = [
      ServerQueryObservation(
        server: first,
        state: .success(QuerySummary(totalQueries: Int.max, totalBlocked: 0), checkedAt: checkedAt)
      ),
      ServerQueryObservation(
        server: second,
        state: .success(QuerySummary(totalQueries: 1, totalBlocked: 0), checkedAt: checkedAt)
      )
    ]

    #expect(ServerQueryObservation.aggregate(observations) == nil)
    #expect(ServerQueryObservation.availability(in: observations) == .allAvailable)
  }

  @Test func notCheckedAndEmptyInputsAreNotChecked() {
    let server = makeServer()
    let notChecked = ServerQueryObservation(server: server, state: .notChecked)

    #expect(ServerQueryObservation.availability(in: [notChecked]) == .notChecked)
    #expect(ServerQueryObservation.availability(in: []) == .notChecked)
  }

  @Test func duplicateIdentifiersCountOnceForAvailability() {
    let server = makeServer()
    let checkedAt = Date(timeIntervalSince1970: 1_000)
    let success = ServerQueryObservation(
      server: server,
      state: .success(QuerySummary(totalQueries: 10, totalBlocked: 1), checkedAt: checkedAt)
    )

    #expect(ServerQueryObservation.availability(in: [success, success]) == .allAvailable)
  }

  @Test func conflictingDuplicatesKeepTheFirstObservationInBothHelpers() {
    let server = makeServer()
    let checkedAt = Date(timeIntervalSince1970: 1_000)
    let failuresFirst = [
      ServerQueryObservation(server: server, state: .failure(.network("offline"), checkedAt: checkedAt)),
      ServerQueryObservation(
        server: server,
        state: .success(QuerySummary(totalQueries: 10, totalBlocked: 1), checkedAt: checkedAt)
      )
    ]

    #expect(ServerQueryObservation.aggregate(failuresFirst) == nil)
    #expect(ServerQueryObservation.availability(in: failuresFirst) == .noneAvailable)
  }

  @Test func successWithAnUncheckedServerIsOnlySomeAvailable() {
    let successServer = makeServer(url: "http://success.local")
    let uncheckedServer = makeServer(url: "http://unchecked.local")
    let checkedAt = Date(timeIntervalSince1970: 1_000)
    let observations = [
      ServerQueryObservation(
        server: successServer,
        state: .success(QuerySummary(totalQueries: 10, totalBlocked: 1), checkedAt: checkedAt)
      ),
      ServerQueryObservation(server: uncheckedServer, state: .notChecked)
    ]

    #expect(ServerQueryObservation.availability(in: observations) == .someAvailable)
  }

  @Test func failureWithAnUncheckedServerIsNoneAvailable() {
    let failureServer = makeServer(url: "http://failure.local")
    let uncheckedServer = makeServer(url: "http://unchecked.local")
    let checkedAt = Date(timeIntervalSince1970: 1_000)
    let observations = [
      ServerQueryObservation(server: failureServer, state: .failure(.network("offline"), checkedAt: checkedAt)),
      ServerQueryObservation(server: uncheckedServer, state: .notChecked)
    ]

    #expect(ServerQueryObservation.availability(in: observations) == .noneAvailable)
  }

  @Test func duplicateIdentifierWithMissingResultKeepsAvailabilityInAgreement() {
    let first = makeServer(url: "http://first.local")
    let second = makeServer(url: "http://second.local")
    let observations = ServerQueryObservation.make(
      servers: [first, first, second],
      results: [first.id: .success(QuerySummary(totalQueries: 10, totalBlocked: 1))],
      checkedAt: Date(timeIntervalSince1970: 1_000)
    )

    #expect(observations.map(\.server) == [first, second])
    #expect(ServerQueryObservation.availability(in: observations) == .someAvailable)
    #expect(ServerQueryObservation.aggregate(observations)?.totalQueries == 10)
  }

  @Test func duplicateFailuresCountOnce() {
    let server = makeServer()
    let observations = ServerQueryObservation.make(
      servers: [server, server],
      results: [server.id: .failure(.network("offline"))],
      checkedAt: Date(timeIntervalSince1970: 1_000)
    )

    #expect(observations.count == 1)
    #expect(ServerQueryObservation.availability(in: observations) == .noneAvailable)
    #expect(ServerQueryObservation.aggregate(observations) == nil)
  }

  private func makeServer(
    url: String = "http://pihole.local",
    version: ServerVersion = .v6
  ) -> ServerConfig {
    ServerConfig(id: UUID(), url: url, version: version)
  }

  private func makeObservations(
    servers: [ServerConfig],
    results: [UUID: Result<QuerySummary, PiholeError>],
    checkedAt: Date? = Date(timeIntervalSince1970: 1_000)
  ) -> [ServerQueryObservation] {
    ServerQueryObservation.make(servers: servers, results: results, checkedAt: checkedAt)
  }
}
