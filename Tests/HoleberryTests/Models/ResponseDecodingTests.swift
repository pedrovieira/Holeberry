import Foundation
import Testing

@testable import Holeberry

// MARK: - v6 response decoding

@Suite("v6 Response Decoding")
struct V6ResponseDecodingTests {
  @Test func checkStatusEnabledDecoding() throws {
    let json = #"{"blocking": true}"#
    let data = try #require(json.data(using: .utf8))
    struct Response: Decodable {
      let blocking: Bool?
      let timer: TimeInterval?
    }
    let status = try JSONDecoder().decode(Response.self, from: data)
    #expect(status.blocking == true)
    #expect(status.timer == nil)
  }

  @Test func checkStatusDisabledWithTimerDecoding() throws {
    let json = #"{"blocking": false, "timer": 180.0}"#
    let data = try #require(json.data(using: .utf8))
    struct Response: Decodable {
      let blocking: Bool?
      let timer: TimeInterval?
    }
    let status = try JSONDecoder().decode(Response.self, from: data)
    #expect(status.blocking == false)
    #expect(status.timer == 180.0)
  }

  @Test func recentBlockedDecoding() throws {
    let json = #"{"blocked": ["doubleclick.net", "ads.com", "tracker.example.com"]}"#
    let data = try #require(json.data(using: .utf8))
    struct Response: Decodable {
      let blocked: [String]
    }
    let result = try JSONDecoder().decode(Response.self, from: data)
    #expect(result.blocked.count == 3)
    #expect(result.blocked[0] == "doubleclick.net")
    #expect(result.blocked[2] == "tracker.example.com")
  }

  @Test func addDomainResponseDecoding() throws {
    let json = #"{"id": 42, "domain": "example.com", "type": 0, "comment": "via holeberryapp.com / test-uuid"}"#
    let data = try #require(json.data(using: .utf8))
    let entry = try JSONDecoder().decode(DomainEntry.self, from: data)
    #expect(entry.id == 42)
    #expect(entry.domain == "example.com")
    #expect(entry.type == 0)
    #expect(entry.comment == "via holeberryapp.com / test-uuid")
  }

  @Test func domainsResponseDecoding() throws {
    let json = """
      {"domains":[
        {"domain":"a.com","type":"allow","comment":""},
        {"domain":"b.com","type":"deny","comment":"x"}]}
      """
    let data = try #require(json.data(using: .utf8))
    let response = try JSONDecoder().decode(DomainsResponse.self, from: data)
    #expect(response.domains.count == 2)
    #expect(response.domains[0].domain == "a.com")
    #expect(response.domains[0].type == 0)
    #expect(response.domains[1].domain == "b.com")
    #expect(response.domains[1].type == 1)
    #expect(response.domains[1].comment == "x")
  }

  @Test func domainsResponseDecodingIntegerTypes() throws {
    let json =
      #"[{"id":1,"domain":"allowed.com","type":0,"comment":""},{"id":2,"domain":"blocked.com","type":1,"comment":"manual block"}]"#
    let data = try #require(json.data(using: .utf8))
    let entries = try JSONDecoder().decode([DomainEntry].self, from: data)
    #expect(entries.count == 2)
    #expect(entries[0].domain == "allowed.com")
    #expect(entries[0].type == 0)
    #expect(entries[1].domain == "blocked.com")
    #expect(entries[1].type == 1)
    #expect(entries[1].comment == "manual block")
  }
}

// MARK: - v5 response decoding

@Suite("v5 Response Decoding")
struct V5ResponseDecodingTests {
  @Test func checkStatusEnabledDecoding() throws {
    let json = #"{"status": "enabled"}"#
    let data = try #require(json.data(using: .utf8))
    struct StatusResponse: Decodable {
      let status: String?
    }
    let status = try JSONDecoder().decode(StatusResponse.self, from: data)
    #expect(status.status == "enabled")
  }

  @Test func checkStatusDisabledDecoding() throws {
    let json = #"{"status": "disabled"}"#
    let data = try #require(json.data(using: .utf8))
    struct StatusResponse: Decodable {
      let status: String?
    }
    let status = try JSONDecoder().decode(StatusResponse.self, from: data)
    #expect(status.status == "disabled")
  }

  @Test func getAllQueriesDecoding() throws {
    let json =
      #"[["2024-01-15 10:30:00","A","example.com","192.168.1.5","2","OK","0"],["2024-01-15 10:31:00","AAAA","blocked.com","192.168.1.10","1","Blocked","1"],["2024-01-15 10:32:00","A","tracker.net","192.168.1.5","1","Blocked","1"]]"#
    let data = try #require(json.data(using: .utf8))
    let rawJSON = try JSONSerialization.jsonObject(with: data)
    #expect(rawJSON is [[Any]])

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

    let blockedStatuses: Set<String> = ["1", "4", "5", "6"]

    let rawArray = rawJSON as? [[Any]]
    #expect(rawArray != nil)
    let blocked: [BlockedDomain] = (rawArray ?? []).compactMap { row -> BlockedDomain? in
      guard row.count >= 5 else { return nil }
      let status = "\(row[4])"
      guard blockedStatuses.contains(status) else { return nil }
      let domain = "\(row[2])"
      let client = "\(row[3])"
      let timestamp = dateFormatter.date(from: "\(row[0])") ?? Date()
      return BlockedDomain(domain: domain, timestamp: timestamp, fromClientIp: client)
    }

    #expect(blocked.count == 2)
    #expect(blocked[0].domain == "blocked.com")
    #expect(blocked[1].domain == "tracker.net")
  }
}
