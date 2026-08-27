import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@Suite("ServerConfig")
struct ServerConfigTests {
  @Test func defaults() {
    let server = ServerConfig(label: nil, url: "http://192.168.1.100:80", version: .v6)
    #expect(server.id.uuidString.isEmpty == false)
    #expect(server.label == nil)
    #expect(server.url == "http://192.168.1.100:80")
    #expect(server.version == .v6)
  }

  @Test func withLabel() {
    let server = ServerConfig(label: "Home", url: "https://pihole.local:443", version: .v6)
    #expect(server.label == "Home")
    #expect(server.url == "https://pihole.local:443")
  }

  @Test func versionAfterDetection() {
    var server = ServerConfig(label: nil, url: "http://192.168.1.100", version: .v5)
    server.version = .v6
    #expect(server.version == .v6)
  }

  @Test func equality() {
    let id = UUID()
    let server1 = ServerConfig(id: id, label: "A", url: "http://a.com", version: .v6)
    let server2 = ServerConfig(id: id, label: "B", url: "http://b.com", version: .v6)
    #expect(server1 == server2)  // equal by id
  }

  @Test func codableRoundTrip() throws {
    let server = ServerConfig(label: "Test", url: "http://test.com:8080", version: .v6)
    let data = try TestJSON.encoder.encode(server)
    let decoded = try TestJSON.decoder.decode(ServerConfig.self, from: data)
    #expect(server.id == decoded.id)
    #expect(server.label == decoded.label)
    #expect(server.url == decoded.url)
    #expect(server.version == decoded.version)
  }

  @Test func codableNilLabel() throws {
    let server = ServerConfig(label: nil, url: "http://test.com", version: .v5)
    let data = try TestJSON.encoder.encode(server)
    let decoded = try TestJSON.decoder.decode(ServerConfig.self, from: data)
    #expect(decoded.label == nil)
    #expect(decoded.version == .v5)
  }
}
