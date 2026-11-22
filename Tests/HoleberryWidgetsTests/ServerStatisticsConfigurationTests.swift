import AppIntents
import Foundation
import HoleberryCore
import Testing

@Suite("Server statistics configuration")
@MainActor
struct ServerStatisticsConfigurationTests {
  @Test func queryDefaultSelectsAllServers() async {
    let selection = await ServerStatisticsServerQuery().defaultResult()

    #expect(selection == .allServers)
  }

  @Test func absentConfigurationDefaultsToAllServers() {
    let intent = ServerStatisticsConfigurationIntent()

    #expect(intent.server.id == ServerStatisticsServerEntity.allServersIdentifier)
    #expect(intent.server.scope == .all)
    #expect(intent.server.resolution == .aggregate)
  }

  @Test func entityResolutionKeepsAnExplicitUnknownIdentifier() async throws {
    let removedID = UUID()

    let entities = try await ServerStatisticsServerQuery().entities(
      for: [
        ServerStatisticsServerEntity.allServersIdentifier,
        removedID.uuidString
      ]
    )

    #expect(
      entities.map(\.id) == [
        ServerStatisticsServerEntity.allServersIdentifier,
        removedID.uuidString
      ]
    )
    #expect(entities.first?.scope == .all)
    #expect(entities.last?.scope == .server(removedID))
  }

  @Test func entityResolutionCarriesExplicitSemanticState() {
    let id = UUID()
    let saved = ServerConfig(id: id, label: "Kitchen", url: "https://kitchen.example", version: .v6)

    let resolved = ServerStatisticsServerQuery.entity(for: id.uuidString, saved: [saved])
    #expect(resolved.resolution == .saved)
    #expect(resolved.name == "Kitchen")
    #expect(resolved.detail == nil)

    let missing = ServerStatisticsServerQuery.entity(for: id.uuidString, saved: [])
    #expect(missing.resolution == .missing)
    #expect(missing.name == "Server removed")
    #expect(missing.id == id.uuidString)

    let unavailable = ServerStatisticsServerQuery.entity(for: id.uuidString, saved: nil)
    #expect(unavailable.resolution == .unavailable)
    #expect(unavailable.id == id.uuidString)
  }

  @Test func aggregateDisplayCopyIsUnchanged() {
    #expect(ServerStatisticsServerEntity.allServers.displayRepresentation.title.key == "All servers")
  }

  @Test func pickerWithoutSavedServersHasOnlyTheAggregateSection() async throws {
    let suggestions = try await ServerStatisticsServerQuery().suggestedEntities()

    #expect(suggestions.sections.count == 1)
    #expect(suggestions.items == [.allServers])
  }

  @Test func namesUseTheLabelThenHostnameThenURL() {
    let servers = [
      ServerConfig(label: "Kitchen", url: "https://kitchen.example", version: .v6),
      ServerConfig(label: " ", url: "https://192.168.1.20:8080/admin", version: .v6),
      ServerConfig(label: nil, url: "not a url", version: .v6)
    ]

    let choices = ServerStatisticsServerQuery.choices(for: servers)

    #expect(choices.map(\.name) == ["Kitchen", "192.168.1.20", "not a url"])
    #expect(choices.allSatisfy { $0.detail == nil })
  }

  @Test func savedOrderIsPreserved() {
    let first = ServerConfig(label: "First", url: "https://first.example", version: .v6)
    let second = ServerConfig(label: "Second", url: "https://second.example", version: .v5)

    let choices = ServerStatisticsServerQuery.choices(for: [second, first])

    #expect(choices.map(\.id) == [second.id.uuidString, first.id.uuidString])
    #expect(choices.map(\.name) == ["Second", "First"])
  }

  @Test func duplicateLabelsGetDistinctHostnameSubtitles() {
    let first = ServerConfig(label: "Kitchen", url: "http://192.168.1.20", version: .v6)
    let second = ServerConfig(label: "Kitchen", url: "https://kitchen.example", version: .v6)

    let choices = ServerStatisticsServerQuery.choices(for: [first, second])

    #expect(choices.map(\.name) == ["Kitchen", "Kitchen"])
    #expect(choices.map(\.detail) == ["192.168.1.20", "kitchen.example"])
  }

  @Test func duplicateLabelsWithTheSameHostnameUseTheSavedURL() {
    let first = ServerConfig(label: "Pi-hole", url: "http://pihole.local", version: .v6)
    let second = ServerConfig(label: "Pi-hole", url: "https://pihole.local", version: .v6)

    let choices = ServerStatisticsServerQuery.choices(for: [first, second])

    #expect(choices.map(\.detail) == ["http://pihole.local", "https://pihole.local"])
  }

  @Test func duplicatedFallbackNamesAlsoGetSubtitles() {
    let first = ServerConfig(label: nil, url: "http://pihole.local/admin", version: .v6)
    let second = ServerConfig(label: "  ", url: "http://pihole.local:8080/admin", version: .v6)

    let choices = ServerStatisticsServerQuery.choices(for: [first, second])

    #expect(choices.map(\.name) == ["pihole.local", "pihole.local"])
    #expect(choices.allSatisfy { $0.detail != nil })
  }

  @Test func unknownServerUUIDStaysAServerSelection() {
    let removedID = UUID()

    let scope = ServerStatisticsServerQuery.entity(for: removedID.uuidString, saved: []).scope

    #expect(scope == .server(removedID))
    #expect(scope != .all)
  }

  @Test func malformedIdentifierNeverBecomesTheAggregateScope() {
    let scope = ServerStatisticsServerQuery.entity(for: "not-a-uuid", saved: []).scope

    #expect(scope != .all)
  }

  @Test func previewForAggregateKeepsTheGallerySample() throws {
    let entry = QueryStatisticsEntry.preview(for: .allServers)

    #expect(entry.base.scope == .all)
    #expect(entry.content == .statistics)
    #expect(try #require(entry.summary).totalQueries == 184_200)
  }

  @Test func previewForSavedServerKeepsTheSampleEvenWhenItsNameMatchesRemovalCopy() throws {
    let entry = QueryStatisticsEntry.preview(
      for: entity(name: "Server removed", resolution: .saved)
    )

    #expect(entry.content == .statistics)
    #expect(entry.statusText == "Server removed")
    #expect(try #require(entry.summary).totalQueries == 184_200)
  }

  @Test func previewForRemovedServerShowsGuidanceWithoutCounts() {
    let id = UUID()
    let entry = QueryStatisticsEntry.preview(
      for: entity(id: id, name: "Server removed", resolution: .missing)
    )

    #expect(entry.base.scope == .server(id))
    #expect(entry.content == .serverRemoved)
    #expect(entry.summary == nil)
    #expect(entry.accessibilityText == "Server removed. Edit widget to choose another server")
  }

  @Test func previewForUnavailableMetadataShowsSetupWithoutCounts() {
    let entry = QueryStatisticsEntry.preview(
      for: entity(name: "Server", resolution: .unavailable)
    )

    #expect(entry.content == .setupRequired)
    #expect(entry.summary == nil)
    #expect(entry.accessibilityText == "Open Holeberry to finish setup")
  }

  private func entity(
    id: UUID = UUID(),
    name: String,
    resolution: ServerStatisticsServerEntity.Resolution
  ) -> ServerStatisticsServerEntity {
    ServerStatisticsServerEntity(
      id: id.uuidString,
      name: name,
      detail: nil,
      resolution: resolution
    )
  }
}
