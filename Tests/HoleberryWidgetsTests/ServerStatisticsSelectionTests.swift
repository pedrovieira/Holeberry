import Foundation
import HoleberryCore
import Testing

@Suite("Server statistics selection")
@MainActor
struct ServerStatisticsSelectionTests {
  @Test func aggregateIdentifierMapsToTheAggregateScope() {
    let identifier = ServerStatisticsSelection.identifier(for: .all)

    #expect(identifier == ServerStatisticsSelection.allServersIdentifier)
    #expect(ServerStatisticsSelection.scope(for: identifier) == .all)
  }

  @Test func savedServerUUIDsRoundTrip() {
    let id = UUID()

    let identifier = ServerStatisticsSelection.identifier(for: .server(id))

    #expect(identifier == id.uuidString)
    #expect(ServerStatisticsSelection.scope(for: identifier) == .server(id))
  }

  @Test func unknownServerUUIDStaysAServerSelection() {
    let removedID = UUID()

    let scope = ServerStatisticsSelection.scope(for: removedID.uuidString)

    #expect(scope == .server(removedID))
    #expect(scope != .all)
  }

  @Test func malformedIdentifierNeverBecomesTheAggregateScope() {
    let scope = ServerStatisticsSelection.scope(for: "not-a-uuid")

    #expect(scope == .server(ServerStatisticsSelection.unreadableServerID))
    #expect(scope != .all)
  }

  @Test func previewForAggregateKeepsTheGallerySample() throws {
    let entry = ServerStatisticsSelection.previewEntry(for: .allServers)

    #expect(entry.base.scope == .all)
    #expect(entry.content == .statistics)
    #expect(try #require(entry.summary).totalQueries == 184_200)
  }

  @Test func previewForSavedServerKeepsTheSampleEvenWhenItsNameMatchesRemovalCopy() throws {
    let entry = ServerStatisticsSelection.previewEntry(
      for: entity(name: "Server removed", resolution: .saved)
    )

    #expect(entry.content == .statistics)
    #expect(entry.statusText == "Server removed")
    #expect(try #require(entry.summary).totalQueries == 184_200)
  }

  @Test func previewForRemovedServerShowsGuidanceWithoutCounts() {
    let id = UUID()
    let entry = ServerStatisticsSelection.previewEntry(
      for: entity(id: id, name: "Server removed", resolution: .missing)
    )

    #expect(entry.base.scope == .server(id))
    #expect(entry.content == .serverRemoved)
    #expect(entry.summary == nil)
    #expect(entry.accessibilityText == "Server removed. Edit widget to choose another server")
  }

  @Test func previewForUnavailableMetadataShowsSetupWithoutCounts() {
    let entry = ServerStatisticsSelection.previewEntry(
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
