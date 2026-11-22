import Foundation
import HoleberryCore
import Testing

@Suite("Server statistics configuration")
@MainActor
struct ServerStatisticsConfigurationTests {
  @Test func absentConfigurationDefaultsToAllServers() {
    let intent = ServerStatisticsConfigurationIntent()

    #expect(intent.server.id == ServerStatisticsSelection.allServersIdentifier)
    #expect(intent.server.scope == .all)
    #expect(intent.server.resolution == .aggregate)
  }

  @Test func entityResolutionKeepsAnExplicitUnknownIdentifier() async throws {
    let removedID = UUID()

    let entities = try await ServerStatisticsServerQuery().entities(
      for: [
        ServerStatisticsSelection.allServersIdentifier,
        removedID.uuidString
      ]
    )

    #expect(
      entities.map(\.id) == [
        ServerStatisticsSelection.allServersIdentifier,
        removedID.uuidString
      ]
    )
    #expect(entities.first?.scope == .all)
    #expect(entities.last?.scope == .server(removedID))
  }

  @Test func entityResolutionCarriesExplicitSemanticState() {
    let id = UUID()
    let saved = SavedServerMetadata(id: id, name: "Kitchen", detail: "kitchen.example")

    let resolved = ServerStatisticsServerQuery.entity(for: id.uuidString, saved: [saved])
    #expect(resolved.resolution == .saved)
    #expect(resolved.name == "Kitchen")
    #expect(resolved.detail == "kitchen.example")

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
}
