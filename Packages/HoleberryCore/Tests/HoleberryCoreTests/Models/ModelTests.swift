import Foundation
import Testing

@testable import HoleberryCore

// swiftlint:disable identifier_name

// MARK: - BlockedDomain

@Suite("BlockedDomain")
struct BlockedDomainTests {
  @Test("init sets all properties with defaults")
  func initDefaults() {
    let date = Date()
    let domain = BlockedDomain(domain: "example.com", timestamp: date, fromClientIp: "192.168.1.5")
    #expect(domain.domain == "example.com")
    #expect(domain.timestamp == date)
    #expect(domain.count == 1)
    #expect(domain.fromClientIp == "192.168.1.5")
  }

  @Test("init respects explicit count")
  func initExplicitCount() {
    let domain = BlockedDomain(domain: "ads.com", timestamp: Date(), count: 5, fromClientIp: "10.0.0.1")
    #expect(domain.count == 5)
  }

  @Test("Equatable")
  func equatable() {
    let date = Date()
    let a = BlockedDomain(domain: "a.com", timestamp: date, fromClientIp: "1.2.3.4")
    let b = BlockedDomain(domain: "a.com", timestamp: date, fromClientIp: "1.2.3.4")
    let c = BlockedDomain(domain: "b.com", timestamp: date, fromClientIp: "1.2.3.4")
    #expect(a == b)
    #expect(a != c)
  }

  @Test("Codable round-trip")
  func codableRoundTrip() throws {
    let original = BlockedDomain(domain: "tracker.net", timestamp: Date(), count: 3, fromClientIp: "10.0.0.1")
    let data = try TestJSON.encoder.encode(original)
    let decoded = try TestJSON.decoder.decode(BlockedDomain.self, from: data)
    #expect(decoded.domain == original.domain)
    #expect(abs(decoded.timestamp.timeIntervalSince(original.timestamp)) < 0.001)
    #expect(decoded.count == original.count)
    #expect(decoded.fromClientIp == original.fromClientIp)
  }
}

// MARK: - DomainEntry

@Suite("DomainEntry")
struct DomainEntryTests {
  @Test("Convenience init")
  func convenienceInit() {
    let entry = DomainEntry(id: 1, domain: "test.com", type: 0, comment: "a comment")
    #expect(entry.id == 1)
    #expect(entry.domain == "test.com")
    #expect(entry.type == 0)
    #expect(entry.comment == "a comment")
  }

  @Test("Init with nil id and comment")
  func initNilIdComment() {
    let entry = DomainEntry(id: nil, domain: "test.com", type: 1, comment: nil)
    #expect(entry.id == nil)
    #expect(entry.comment == nil)
  }

  @Test("Decode v5 integer type")
  func decodeV5IntegerType() throws {
    let json = #"{"id": 1, "domain": "a.com", "type": 0, "comment": "allow"}"#
    let data = try #require(json.data(using: .utf8))
    let entry = try TestJSON.decoder.decode(DomainEntry.self, from: data)
    #expect(entry.type == 0)
  }

  @Test("Decode v6 string type 'allow'")
  func decodeV6StringTypeAllow() throws {
    let json = #"{"id": 1, "domain": "a.com", "type": "allow", "comment": ""}"#
    let data = try #require(json.data(using: .utf8))
    let entry = try TestJSON.decoder.decode(DomainEntry.self, from: data)
    #expect(entry.type == 0)
  }

  @Test("Decode v6 string type 'deny'")
  func decodeV6StringTypeDeny() throws {
    let json = #"{"id": 2, "domain": "b.com", "type": "deny", "comment": "blocked"}"#
    let data = try #require(json.data(using: .utf8))
    let entry = try TestJSON.decoder.decode(DomainEntry.self, from: data)
    #expect(entry.type == 1)
  }

  @Test("Equatable")
  func equatable() {
    let a = DomainEntry(id: 1, domain: "a.com", type: 0, comment: nil)
    let b = DomainEntry(id: 1, domain: "a.com", type: 0, comment: nil)
    let c = DomainEntry(id: 2, domain: "b.com", type: 1, comment: nil)
    #expect(a == b)
    #expect(a != c)
  }

  @Test("Codable round-trip")
  func codableRoundTrip() throws {
    let original = DomainEntry(id: 42, domain: "example.com", type: 0, comment: "test")
    let data = try TestJSON.encoder.encode(original)
    let decoded = try TestJSON.decoder.decode(DomainEntry.self, from: data)
    #expect(decoded.id == original.id)
    #expect(decoded.domain == original.domain)
    #expect(decoded.type == original.type)
    #expect(decoded.comment == original.comment)
  }
}

// MARK: - DomainListType

@Suite("DomainListType")
struct DomainListTypeTests {
  @Test("allow raw value is 0")
  func allowRawValue() {
    #expect(DomainListType.allow.rawValue == 0)
  }

  @Test("deny raw value is 1")
  func denyRawValue() {
    #expect(DomainListType.deny.rawValue == 1)
  }
}

// MARK: - ServerVersion

@Suite("ServerVersion")
struct ServerVersionTests {
  @Test("displayName for v5")
  func displayNameV5() {
    #expect(ServerVersion.v5.displayName == "Pi-hole v5")
  }

  @Test("displayName for v6")
  func displayNameV6() {
    #expect(ServerVersion.v6.displayName == "Pi-hole v6")
  }

  @Test("allCases")
  func allCases() {
    #expect(ServerVersion.allCases == [.v5, .v6])
  }

  @Test("Codable round-trip")
  func codableRoundTrip() throws {
    for version in ServerVersion.allCases {
      let data = try TestJSON.encoder.encode(version)
      let decoded = try TestJSON.decoder.decode(ServerVersion.self, from: data)
      #expect(decoded == version)
    }
  }
}

// MARK: - QuerySummary

@Suite("QuerySummary")
struct QuerySummaryTests {
  @Test("init")
  func initTest() {
    let summary = QuerySummary(totalQueries: 100, totalBlocked: 25)
    #expect(summary.totalQueries == 100)
    #expect(summary.totalBlocked == 25)
  }

  @Test("zero values")
  func zeroValues() {
    let summary = QuerySummary(totalQueries: 0, totalBlocked: 0)
    #expect(summary.totalQueries == 0)
    #expect(summary.totalBlocked == 0)
  }
}

// MARK: - HTTPMethod

@Suite("HTTPMethod")
struct HTTPMethodTests {
  @Test("raw values")
  func rawValues() {
    #expect(HTTPMethod.get.rawValue == "GET")
    #expect(HTTPMethod.post.rawValue == "POST")
    #expect(HTTPMethod.delete.rawValue == "DELETE")
  }
}
