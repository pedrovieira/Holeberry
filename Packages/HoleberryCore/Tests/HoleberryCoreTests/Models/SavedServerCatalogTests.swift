import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("Saved server catalog")
struct SavedServerCatalogTests {
  @Test func namesUseTheLabelThenHostnameThenURL() {
    let servers = [
      ServerConfig(label: "Kitchen", url: "https://kitchen.example", version: .v6),
      ServerConfig(label: " ", url: "https://192.168.1.20:8080/admin", version: .v6),
      ServerConfig(label: nil, url: "not a url", version: .v6)
    ]

    let metadata = SavedServerCatalog.metadata(for: servers)

    #expect(metadata.map(\.name) == ["Kitchen", "192.168.1.20", "not a url"])
    #expect(metadata.allSatisfy { $0.detail == nil })
  }

  @Test func savedOrderIsPreserved() {
    let first = ServerConfig(label: "First", url: "https://first.example", version: .v6)
    let second = ServerConfig(label: "Second", url: "https://second.example", version: .v5)

    let metadata = SavedServerCatalog.metadata(for: [second, first])

    #expect(metadata.map(\.id) == [second.id, first.id])
    #expect(metadata.map(\.name) == ["Second", "First"])
  }

  @Test func duplicateLabelsGetDistinctHostnameSubtitles() {
    let first = ServerConfig(label: "Kitchen", url: "http://192.168.1.20", version: .v6)
    let second = ServerConfig(label: "Kitchen", url: "https://kitchen.example", version: .v6)

    let metadata = SavedServerCatalog.metadata(for: [first, second])

    #expect(metadata.map(\.name) == ["Kitchen", "Kitchen"])
    #expect(metadata.map(\.detail) == ["192.168.1.20", "kitchen.example"])
  }

  @Test func duplicateLabelsWithTheSameHostnameUseTheSavedURL() {
    let first = ServerConfig(label: "Pi-hole", url: "http://pihole.local", version: .v6)
    let second = ServerConfig(label: "Pi-hole", url: "https://pihole.local", version: .v6)

    let metadata = SavedServerCatalog.metadata(for: [first, second])

    #expect(metadata.map(\.detail) == ["http://pihole.local", "https://pihole.local"])
  }

  @Test func duplicatedFallbackNamesAlsoGetSubtitles() {
    let first = ServerConfig(label: nil, url: "http://pihole.local/admin", version: .v6)
    let second = ServerConfig(label: "  ", url: "http://pihole.local:8080/admin", version: .v6)

    let metadata = SavedServerCatalog.metadata(for: [first, second])

    #expect(metadata.map(\.name) == ["pihole.local", "pihole.local"])
    #expect(metadata.allSatisfy { $0.detail != nil })
  }

  @Test func metadataIsUnavailableBeforeSharedStorageIsReady() {
    let (name, suite) = TestDefaults.makeNamedSuite()

    #expect(SavedServerCatalog.metadata(in: suite, suiteName: name) == nil)
  }

  @Test func metadataReadsTheSavedListOnceReady() {
    let (name, suite) = TestDefaults.makeNamedSuite()
    let server = ServerConfig(label: "Kitchen", url: "https://kitchen.example", version: .v6)
    Defaults[.servers(suite: suite)] = [server]
    Defaults[.sharedStorageMigrationVersion(suite: suite)] = SharedStorageMigration.currentVersion

    let metadata = SavedServerCatalog.metadata(in: suite, suiteName: name)

    #expect(metadata == [SavedServerMetadata(id: server.id, name: "Kitchen", detail: nil)])
  }
}
