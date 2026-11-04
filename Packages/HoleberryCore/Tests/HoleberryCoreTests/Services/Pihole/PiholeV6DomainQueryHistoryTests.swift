import Foundation
import Testing

@testable import HoleberryCore

@Suite("PiholeV6DomainQueryHistory")
@MainActor
struct PiholeV6DomainQueryHistoryTests {
  private let interval = DateInterval(start: Date(timeIntervalSince1970: 1000.25), duration: 900)

  private func service(_ session: MockURLSession, auth: MockAuthSessionProvider = MockAuthSessionProvider())
    -> PiholeV6Service
  {
    PiholeV6Service(
      id: UUID(), label: nil, url: "http://pihole", version: .v6,
      baseURL: URL(string: "http://pihole")!, urlSession: session, authSession: auth)
  }

  private func row(status: String = "GRAVITY", client: String = "192.168.1.50", reply: String = "IP") -> [String: Any] {
    [
      "id": 123, "time": 1100.5, "type": "A", "domain": "example.com", "status": status,
      "client": ["ip": client, "name": NSNull()], "reply": ["type": reply, "time": 0.01]
    ]
  }

  private func addPage(
    _ session: MockURLSession, rows: [[String: Any]], cursor: Int? = 1000,
    total: Int? = nil
  ) throws {
    var json: [String: Any] = ["queries": rows]
    if let cursor { json["cursor"] = cursor }
    if let total { json["recordsFiltered"] = total }
    let data = try JSONSerialization.data(withJSONObject: json)
    session.handlers.append { request in
      (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
  }

  @Test func exactDomainRequestAndLocalClientFilter() async throws {
    let session = MockURLSession()
    try addPage(session, rows: [row(), row(client: "192.168.1.51")])
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(history.entries.count == 1)
    #expect(history.entries.allSatisfy { $0.clientIP == "192.168.1.50" })
    #expect(history.isComplete)
    let request = try #require(session.requests.first)
    let items = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(items.contains(URLQueryItem(name: "domain", value: "example.com")))
    #expect(items.contains(URLQueryItem(name: "client_ip", value: "192.168.1.50")))
    #expect(items.contains(URLQueryItem(name: "from", value: "1000.25")))
    #expect(items.contains(URLQueryItem(name: "until", value: "1900.25")))
    #expect(items.contains(URLQueryItem(name: "length", value: "50")))
    #expect(!items.contains { ["status", "upstream"].contains($0.name) })
    #expect(request.value(forHTTPHeaderField: "X-FTL-SID") == "mock-sid")
    #expect(request.timeoutInterval == 15)
  }

  @Test(arguments: [
    "GRAVITY", "REGEX", "DENYLIST", "GRAVITY_CNAME", "REGEX_CNAME", "DENYLIST_CNAME",
    "EXTERNAL_BLOCKED_IP", "EXTERNAL_BLOCKED_NULL", "EXTERNAL_BLOCKED_NXRA", "EXTERNAL_BLOCKED_EDE15",
    "FORWARDED", "CACHE", "CACHE_STALE", "RETRIED", "RETRIED_DNSSEC", "DBBUSY", "SPECIAL_DOMAIN", "UNKNOWN",
    "IN_PROGRESS", "FUTURE_STATUS"
  ])
  func statusClassification(_ status: String) async throws {
    let session = MockURLSession()
    try addPage(session, rows: [row(status: status)])
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    let expected: DomainQueryHandling
    switch status {
    case "GRAVITY", "REGEX", "DENYLIST", "GRAVITY_CNAME", "REGEX_CNAME", "DENYLIST_CNAME": expected = .ruleBlocked
    case "EXTERNAL_BLOCKED_IP", "EXTERNAL_BLOCKED_NULL", "EXTERNAL_BLOCKED_NXRA", "EXTERNAL_BLOCKED_EDE15":
      expected = .upstreamBlocked
    case "FORWARDED", "CACHE", "CACHE_STALE", "RETRIED", "RETRIED_DNSSEC": expected = .permitted
    default: expected = .inconclusive
    }
    #expect(history.entries.first?.handling == expected)
    #expect(history.entries.first?.reply == "IP")
  }

  @Test(arguments: ["UNKNOWN", "NONE", "SERVFAIL", "REFUSED", "FUTURE_REPLY"])
  func unfinishedOrFailedReplyIsInconclusive(_ reply: String) async throws {
    let session = MockURLSession()
    try addPage(session, rows: [row(status: "FORWARDED", reply: reply)])
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(history.entries.first?.handling == .inconclusive)
  }

  @Test func localDomainAndHalfOpenTimeFilter() async throws {
    let session = MockURLSession()
    var atStart = row()
    atStart["time"] = 1000.25
    var atEnd = row()
    atEnd["time"] = 1900.25
    var tooOld = row()
    tooOld["time"] = 1000.24
    var wrongDomain = row()
    wrongDomain["domain"] = "www.example.com"
    try addPage(session, rows: [atStart, atEnd, tooOld, wrongDomain])
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(history.entries.count == 1)
    #expect(history.entries.first?.timestamp == interval.start)
  }

  @Test func nullableStatusAndReplyRemainInconclusive() async throws {
    let session = MockURLSession()
    var unfinished = row()
    unfinished["status"] = NSNull()
    unfinished["reply"] = ["type": NSNull(), "time": 0]
    try addPage(session, rows: [unfinished])
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(history.entries.first?.handling == .inconclusive)
  }

  @Test func fullPagesWithoutCountRemainBounded() async throws {
    let session = MockURLSession()
    for _ in 0..<3 { try addPage(session, rows: Array(repeating: row(), count: 50)) }
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(session.requests.count == 3)
    #expect(!history.isComplete)
  }

  @Test func threePageCapPinsFirstCursor() async throws {
    let session = MockURLSession()
    for cursor in [1000, 2000, 3000] {
      try addPage(session, rows: Array(repeating: row(), count: 50), cursor: cursor, total: 200)
    }
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(session.requests.count == 3)
    #expect(history.entries.count == 150)
    #expect(history.isComplete == false)
    for (index, request) in session.requests.enumerated() {
      let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      #expect(items.contains(URLQueryItem(name: "start", value: String(index * 50))))
      if index > 0 { #expect(items.contains(URLQueryItem(name: "cursor", value: "1000"))) }
    }
  }

  @Test func countMetadataEstablishesExhaustion() async throws {
    let session = MockURLSession()
    try addPage(session, rows: Array(repeating: row(), count: 50), total: 50)
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(history.isComplete)
    #expect(session.requests.count == 1)
  }

  @Test func shortSecondPageIsCompleteWithoutCount() async throws {
    let session = MockURLSession()
    try addPage(session, rows: Array(repeating: row(), count: 50))
    try addPage(session, rows: [row()])
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(history.entries.count == 51)
    #expect(history.isComplete)
  }

  @Test func fullPageWithoutCursorIsIncomplete() async throws {
    let session = MockURLSession()
    try addPage(session, rows: Array(repeating: row(), count: 50), cursor: nil)
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(!history.isComplete)
    #expect(session.requests.count == 1)
  }

  @Test func emptyHistoryIsComplete() async throws {
    let session = MockURLSession()
    try addPage(session, rows: [])
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(history == DomainQueryHistory(entries: [], isComplete: true))
  }

  @Test func hiddenHistoryIsIncomplete() async throws {
    let session = MockURLSession()
    session.handlers = [
      { request in
        (
          Data(#"{"queries":[],"cursor":null}"#.utf8),
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      }
    ]
    let history = try await service(session).getDomainQueryHistory(
      domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    #expect(history == DomainQueryHistory(entries: [], isComplete: false))
  }

  @Test(arguments: ["domain", "time", "type", "client"])
  func malformedRequiredFieldThrows(_ field: String) async throws {
    let session = MockURLSession()
    var invalid = row()
    invalid.removeValue(forKey: field)
    try addPage(session, rows: [invalid])
    do {
      _ = try await service(session).getDomainQueryHistory(
        domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
      Issue.record("Malformed entry must throw")
    } catch PiholeError.decoding {} catch { Issue.record("Unexpected error: \(error)") }
  }

  @Test func laterPageFailureThrows() async throws {
    let session = MockURLSession()
    try addPage(session, rows: Array(repeating: row(), count: 50))
    session.handlers.append { request in
      (Data("failed".utf8), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
    }
    await #expect(throws: PiholeError.server(503, "failed")) {
      try await service(session).getDomainQueryHistory(
        domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    }
  }

  @Test func authenticationFailurePreserved() async {
    let auth = MockAuthSessionProvider()
    auth.authorizedRequestStub = { _ in throw PiholeError.unauthorized }
    await #expect(throws: PiholeError.unauthorized) {
      try await service(MockURLSession(), auth: auth).getDomainQueryHistory(
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

  @Test("Cancellation wins over a successful final page", arguments: [0, 1, 50])
  func cancellationAfterSuccessfulResponse(rowCount: Int) async throws {
    let session = MockURLSession()
    let data = try JSONSerialization.data(withJSONObject: [
      "queries": Array(repeating: row(), count: rowCount), "cursor": 1000, "recordsFiltered": rowCount
    ])
    session.handlers = [
      { request in
        withUnsafeCurrentTask { $0?.cancel() }
        return (
          data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      }
    ]
    let service = service(session)
    let interval = interval
    let task = Task {
      try await service.getDomainQueryHistory(
        domain: "example.com", forClientIP: "192.168.1.50", interval: interval)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }
}
