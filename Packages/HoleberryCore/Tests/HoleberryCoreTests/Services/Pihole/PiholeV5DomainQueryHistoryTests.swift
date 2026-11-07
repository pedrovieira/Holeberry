import Foundation
import Testing

@testable import HoleberryCore

@Suite("PiholeV5DomainQueryHistory")
@MainActor
struct PiholeV5DomainQueryHistoryTests {
  private let interval = DateInterval(start: Date(timeIntervalSince1970: 1000.25), duration: 900)

  private func service(_ session: MockURLSession) -> PiholeV5Service {
    PiholeV5Service(
      id: UUID(), label: nil, url: "http://pihole", version: .v5,
      baseURL: URL(string: "http://pihole")!, session: session, apiToken: "token")
  }

  private func session(_ body: String, status: Int = 200) -> MockURLSession {
    let session = MockURLSession()
    session.handlers = [
      { request in
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
      }
    ]
    return session
  }

  @Test func sharedV5QueryLogUsesUnixTimestamps() async throws {
    let interval = DateInterval(start: Date(timeIntervalSince1970: 1_700_000_000), duration: 3600)
    let history = try await service(session(V5QueryLogFixture.response)).getDomainQueryHistory(
      domain: "allowed.com", forClientIP: "192.168.1.5", interval: interval)
    #expect(history.isComplete)
    #expect(history.entries.count == 1)
    #expect(history.entries.first?.timestamp == Date(timeIntervalSince1970: 1_700_002_700))
    #expect(history.entries.first?.handling == .permitted)
  }

  @Test func timeWindowRequestAndLocalScope() async throws {
    let session = session(
      """
      {"data":[
        [1000.25,"A","EXAMPLE.COM","192.168.1.50","1","0","4"],
        ["1100.5","AAAA","example.com","192.168.1.50","3","0","4"],
        [1100,"A","example.com","192.168.1.51","1","0","4"],
        [1100,"A","www.example.com","192.168.1.50","1","0","4"],
        [999,"A","example.com","192.168.1.50","1","0","4"],
        [1900.25,"A","example.com","192.168.1.50","1","0","4"]
      ]}
      """)
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(history.isComplete)
    #expect(history.entries.count == 2)
    #expect(history.entries.allSatisfy { $0.clientIP == "192.168.1.50" })
    #expect(history.entries.allSatisfy { $0.domain == "example.com" })
    #expect(history.entries.map(\.handling) == [.ruleBlocked, .permitted])
    #expect(history.entries[1].timestamp.timeIntervalSince1970 == 1100.5)
    let request = try #require(session.requests.first)
    let items = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(items.contains(URLQueryItem(name: "getAllQueries", value: nil)))
    #expect(items.contains(URLQueryItem(name: "from", value: "1000")))
    #expect(items.contains(URLQueryItem(name: "until", value: "1901")))
    #expect(items.contains(URLQueryItem(name: "auth", value: "token")))
    #expect(!items.contains { ["domain", "status", "client"].contains($0.name) })
    #expect(session.requests.count == 1)
    #expect(request.timeoutInterval == 15)
  }

  @Test(arguments: [1, 4, 5, 9, 10, 11, 6, 7, 8, 18, 2, 3, 12, 13, 17, 0, 14, 15, 16, 99])
  func statusClassification(_ status: Int) async throws {
    let session = session("{\"data\":[[1100,\"A\",\"example.com\",\"192.168.1.50\",\"\(status)\",\"0\",\"4\"]]}")
    let result = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    let expected: DomainQueryHandling
    switch status {
    case 1, 4, 5, 9, 10, 11: expected = .ruleBlocked
    case 6, 7, 8, 18: expected = .upstreamBlocked
    case 2, 3, 12, 13, 17: expected = .permitted
    default: expected = .inconclusive
    }
    #expect(result.entries.first?.handling == expected)
    #expect(result.entries.first?.status == String(status))
  }

  @Test(arguments: [
    "{}", "{\"FTLnotrunning\":true}", "{\"data\":[[\"bad date\",\"A\",\"example.com\",\"192.168.1.50\",1]]}",
    "{\"data\":[[1100,\"A\"]]}", "{\"data\":[[true,\"A\",\"example.com\",\"192.168.1.50\",1]]}"
  ])
  func malformedHistoryThrows(_ body: String) async {
    let session = session(body)
    do {
      _ = try await service(session).getDomainQueryHistory(
        domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
      Issue.record("Malformed history must not become empty success")
    } catch PiholeError.decoding {} catch { Issue.record("Unexpected error: \(error)") }
  }

  @Test func hugeNumericCellsCannotTrap() async throws {
    let session = session(
      #"{"data":[[1e30,"A","example.com","192.168.1.50",1,"0","4"],[1100,"A","example.com","192.168.1.50",1e30,"0","4"]]}"#
    )
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(history.entries.count == 1)
    #expect(history.entries.first?.handling == .inconclusive)
  }

  @Test func emptyHistory() async throws {
    let history = try await service(session("{\"data\":[]}")).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(history == DomainQueryHistory(entries: [], isComplete: true))
  }

  @Test func rootAndOtherDNSNamesDoNotBreakHistory() async throws {
    let session = session(
      #"{"data":[[1100,"NS",".","192.168.1.50","2","0","6"],[1100,"TXT","name with spaces.local","192.168.1.50","3","0","6"],[1100,"A","example.com","192.168.1.50","1","0","4"]]}"#
    )
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(history.entries.count == 1)
    #expect(history.entries.first?.handling == .ruleBlocked)
    #expect(session.requests.count == 1)
  }

  @Test func namedClientUsesServerMapping() async throws {
    let session = session(
      #"{"data":[[1100,"A","example.com","MACBOOK.LAN.","1","0","4"],[1200,"A","example.com","other.lan","3","0","4"],[1100,"A","other.com","unmapped.lan","1","0","4"]]}"#
    )
    session.handlers.append { request in
      let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      #expect(items.contains(URLQueryItem(name: "getClientNames", value: nil)))
      #expect(items.contains(URLQueryItem(name: "auth", value: "token")))
      #expect(!items.contains { ["getAllQueries", "domain", "from", "until", "client"].contains($0.name) })
      return (
        Data(
          #"{"clients":[{"name":"macbook.lan","ip":"192.168.1.50"},{"name":"other.lan","ip":"192.168.1.51"},{"name":"unrelated-alias","ip":"aliasclient-1"}]}"#
            .utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(session.requests.count == 2)
    #expect(history.entries.count == 1)
    #expect(history.entries.first?.clientIP == "192.168.1.50")
    #expect(history.entries.first?.handling == .ruleBlocked)
  }

  @Test func failedClientMappingThrows() async {
    let session = session(#"{"data":[[1100,"A","example.com","macbook.lan","1","0","4"]]}"#)
    session.handlers.append { _ in throw URLError(.notConnectedToInternet) }
    do {
      _ = try await service(session).getDomainQueryHistory(
        domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
      Issue.record("Client verification failure must throw")
    } catch PiholeError.network {} catch { Issue.record("Unexpected error: \(error)") }
  }

  @Test(arguments: [
    #"{"clients":[]}"#,
    #"{"clients":[{"name":"macbook.lan","ip":"192.168.1.50"},{"name":"MACBOOK.LAN.","ip":"192.168.1.51"}]}"#,
    #"{"clients":[{"name":"macbook.lan","ip":"192.168.1.50"},{"name":"macbook.lan","ip":"fe80::1234"}]}"#,
    #"{"clients":[{"name":"macbook.lan","ip":"invalid"}]}"#,
    #"{"clients":[{"name":"macbook.lan"}]}"#,
    #"{"clients":[{"name":"hidden","ip":"192.168.1.50"}]}"#,
    #"{}"#
  ])
  func unresolvedOrAmbiguousClientCannotBecomeEvidence(_ mapping: String) async {
    let session = session(
      #"{"data":[[1100,"A","example.com","macbook.lan","1","0","4"],[1200,"A","example.com","macbook.lan","3","0","4"]]}"#
    )
    session.handlers.append { request in
      (Data(mapping.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    do {
      _ = try await service(session).getDomainQueryHistory(
        domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
      Issue.record("Unverifiable client names must not become evidence")
    } catch PiholeError.decoding {} catch { Issue.record("Unexpected error: \(error)") }
    #expect(session.requests.count == 2)
  }

  @Test func otherClientsAndIrrelevantNamedRowsAreIgnored() async throws {
    let session = session(
      #"{"data":[[1100,"A","example.com","192.168.1.50","1","0","4"],[1200,"A","example.com","192.168.1.51","3","0","4"],[1200,"A","other.com","unmapped.lan","1","0","4"],[999,"A","example.com","unmapped.lan","1","0","4"]]}"#
    )
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(history.entries.count == 1)
    #expect(history.entries.first?.handling == .ruleBlocked)
    #expect(session.requests.count == 1, "Irrelevant names must not trigger a mapping request")
  }

  @Test func latestNamedAllowedQuerySupersedesNamedBlock() async throws {
    let session = session(
      #"{"data":[[1100,"A","example.com","macbook.lan","1","0","4"],[1200,"A","example.com","macbook.lan","3","0","4"]]}"#
    )
    session.handlers.append { request in
      (
        Data(#"{"clients":[{"name":"macbook.lan","ip":"192.168.1.50"}]}"#.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(
      BrowserDomainUnblockPolicy.evaluate(
        history, domain: "example.com", clientIP: "192.168.1.50", interval: interval) == .notBlocked)
  }

  @Test func directIPMatchesSkipNameLookup() async throws {
    let session = session(
      #"{"data":[[1100,"A","example.com","192.168.1.50","1","0","4"],[1200,"A","example.com","another-device.lan","3","0","4"]]}"#
    )
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(history.entries.count == 1)
    #expect(history.entries.first?.handling == .ruleBlocked)
    #expect(session.requests.count == 1, "Direct IP evidence must not depend on resolving other clients' names")
  }

  @Test func fallbackOnlyResolvesNamesForCapturedIP() async throws {
    let session = session(
      #"{"data":[[1100,"A","example.com","macbook.lan","1","0","4"],[1200,"A","example.com","unmapped-other-device.lan","3","0","4"]]}"#
    )
    session.handlers.append { request in
      (
        Data(#"{"clients":[{"name":"macbook.lan","ip":"192.168.1.50"}]}"#.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(history.entries.count == 1)
    #expect(history.entries.first?.handling == .ruleBlocked)
    #expect(session.requests.count == 2)
  }

  @Test func fallbackDoesNotUseAnotherClientsQueries() async throws {
    let session = session(#"{"data":[[1100,"A","example.com","another-device.lan","1","0","4"]]}"#)
    session.handlers.append { request in
      (
        Data(
          #"{"clients":[{"name":"macbook.lan","ip":"192.168.1.50"},{"name":"another-device.lan","ip":"192.168.1.51"}]}"#
            .utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(history.entries.isEmpty)
    #expect(history.isComplete)
    #expect(session.requests.count == 2)
  }

  @Test func httpErrorPreserved() async {
    let session = session("denied", status: 401)
    await #expect(throws: PiholeError.server(401, "denied")) {
      try await service(session).getDomainQueryHistory(
        domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    }
  }

  @Test func cancellationPreserved() async {
    let session = MockURLSession()
    session.handlers = [{ _ in throw URLError(.cancelled) }]
    await #expect(throws: CancellationError.self) {
      try await service(session).getDomainQueryHistory(
        domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    }
  }
}
