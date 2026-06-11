import XCTest

@testable import PiHoleMenuApp

final class PiHoleMenuAppTests: XCTestCase {
  // MARK: - BlockingStatus tests

  func testBlockingStatusEquality() {
    XCTAssertEqual(BlockingStatus.enabled, BlockingStatus.enabled)
    XCTAssertEqual(BlockingStatus.disabled(remainingSeconds: nil), BlockingStatus.disabled(remainingSeconds: nil))
    XCTAssertEqual(BlockingStatus.disabled(remainingSeconds: 30), BlockingStatus.disabled(remainingSeconds: 30))
    XCTAssertNotEqual(BlockingStatus.enabled, BlockingStatus.disabled(remainingSeconds: nil))
    XCTAssertNotEqual(BlockingStatus.disabled(remainingSeconds: 10), BlockingStatus.disabled(remainingSeconds: 30))
  }

  // MARK: - PiholeError tests

  func testPiholeErrorDescriptions() {
    XCTAssertEqual(PiholeError.unauthorized.errorDescription, "Authentication failed")
    XCTAssertEqual(PiholeError.network("timeout").errorDescription, "Network error: timeout")
    XCTAssertEqual(PiholeError.server(500, nil).errorDescription, "Server error (500)")
    XCTAssertEqual(
      PiholeError.server(500, "Internal Server Error").errorDescription, "Server error (500): Internal Server Error")
    XCTAssertEqual(PiholeError.tlsUntrusted.errorDescription, "Untrusted TLS certificate")
    XCTAssertEqual(PiholeError.duplicateDomain.errorDescription, "Domain is already in the list")
    XCTAssertEqual(PiholeError.decoding("bad JSON").errorDescription, "Failed to parse response: bad JSON")
    XCTAssertEqual(PiholeError.totpRequired.errorDescription, "TOTP code required for 2FA")
    XCTAssertEqual(PiholeError.unknown("something broke").errorDescription, "Unexpected error: something broke")
  }

  func testPiholeErrorEquality() {
    XCTAssertEqual(PiholeError.unauthorized, PiholeError.unauthorized)
    XCTAssertNotEqual(PiholeError.unauthorized, PiholeError.totpRequired)
    XCTAssertEqual(PiholeError.duplicateDomain, PiholeError.duplicateDomain)
    XCTAssertEqual(PiholeError.network("x"), PiholeError.network("x"))
    XCTAssertNotEqual(PiholeError.network("x"), PiholeError.network("y"))
  }

  // MARK: - v6 response decoding tests

  func testV6CheckStatusEnabledDecoding() throws {
    let json = """
      {"blocking": true}
      """
    let data = try XCTUnwrap(json.data(using: .utf8))
    struct Response: Decodable {
      let blocking: Bool?
      let timer: TimeInterval?
    }
    let status = try JSONDecoder().decode(Response.self, from: data)
    XCTAssertEqual(status.blocking, true)
    XCTAssertNil(status.timer)
  }

  func testV6CheckStatusDisabledWithTimerDecoding() throws {
    let json = """
      {"blocking": false, "timer": 180.0}
      """
    let data = try XCTUnwrap(json.data(using: .utf8))
    struct Response: Decodable {
      let blocking: Bool?
      let timer: TimeInterval?
    }
    let status = try JSONDecoder().decode(Response.self, from: data)
    XCTAssertEqual(status.blocking, false)
    XCTAssertEqual(status.timer, 180.0)
  }

  func testV6RecentBlockedDecoding() throws {
    let json = """
      {"blocked": ["doubleclick.net", "ads.com", "tracker.example.com"]}
      """
    let data = try XCTUnwrap(json.data(using: .utf8))
    struct Response: Decodable {
      let blocked: [String]
    }
    let result = try JSONDecoder().decode(Response.self, from: data)
    XCTAssertEqual(result.blocked.count, 3)
    XCTAssertEqual(result.blocked[0], "doubleclick.net")
    XCTAssertEqual(result.blocked[2], "tracker.example.com")
  }

  func testV6AddDomainResponseDecoding() throws {
    let json = """
      {"id": 42, "domain": "example.com", "type": 0, "comment": "pihole-menu-app:test-uuid"}
      """
    let data = try XCTUnwrap(json.data(using: .utf8))
    let entry = try JSONDecoder().decode(DomainEntry.self, from: data)
    XCTAssertEqual(entry.id, 42)
    XCTAssertEqual(entry.domain, "example.com")
    XCTAssertEqual(entry.type, 0)
    XCTAssertEqual(entry.comment, "pihole-menu-app:test-uuid")
  }

  func testV6DomainsResponseDecoding() throws {
    let json = """
      [
        {"id": 1, "domain": "allowed.com", "type": 0, "comment": ""},
        {"id": 2, "domain": "blocked.com", "type": 1, "comment": "manual block"}
      ]
      """
    let data = try XCTUnwrap(json.data(using: .utf8))
    let entries = try JSONDecoder().decode([DomainEntry].self, from: data)
    XCTAssertEqual(entries.count, 2)
    XCTAssertEqual(entries[0].domain, "allowed.com")
    XCTAssertEqual(entries[0].type, 0)
    XCTAssertEqual(entries[1].domain, "blocked.com")
    XCTAssertEqual(entries[1].type, 1)
    XCTAssertEqual(entries[1].comment, "manual block")
  }

  // MARK: - v5 response decoding tests

  func testV5CheckStatusEnabledDecoding() throws {
    let json = """
      {"status": "enabled"}
      """
    let data = try XCTUnwrap(json.data(using: .utf8))
    struct StatusResponse: Decodable {
      let status: String?
    }
    let status = try JSONDecoder().decode(StatusResponse.self, from: data)
    XCTAssertEqual(status.status, "enabled")
  }

  func testV5CheckStatusDisabledDecoding() throws {
    let json = """
      {"status": "disabled"}
      """
    let data = try XCTUnwrap(json.data(using: .utf8))
    struct StatusResponse: Decodable {
      let status: String?
    }
    let status = try JSONDecoder().decode(StatusResponse.self, from: data)
    XCTAssertEqual(status.status, "disabled")
  }

  func testV5GetAllQueriesDecoding() throws {
    let json = """
      [
        ["2024-01-15 10:30:00", "A", "example.com", "192.168.1.5", "2", "OK", "0"],
        ["2024-01-15 10:31:00", "AAAA", "blocked.com", "192.168.1.10", "0", "Blocked", "1"],
        ["2024-01-15 10:32:00", "A", "tracker.net", "192.168.1.5", "0", "Blocked", "1"]
      ]
      """
    let data = try XCTUnwrap(json.data(using: .utf8))
    guard let rawJSON = try JSONSerialization.jsonObject(with: data) as? [[Any]] else {
      XCTFail("Expected array of arrays")
      return
    }

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

    var queries: [RecentQuery] = []
    for row in rawJSON {
      guard row.count >= 5 else { continue }
      let timestamp = dateFormatter.date(from: "\(row[0])") ?? Date()
      let dnsType = "\(row[1])"
      let domain = "\(row[2])"
      let clientIP = "\(row[3])"
      let status = "\(row[4])"

      queries.append(
        RecentQuery(
          timestamp: timestamp,
          domain: domain,
          clientIP: clientIP,
          status: status,
          dnsType: dnsType
        ))
    }

    XCTAssertEqual(queries.count, 3)
    XCTAssertEqual(queries[0].domain, "example.com")
    XCTAssertEqual(queries[0].status, "2")
    XCTAssertEqual(queries[1].domain, "blocked.com")
    XCTAssertEqual(queries[1].status, "0")
    XCTAssertEqual(queries[2].dnsType, "A")
  }

  // MARK: - v5 HTML parsing tests

  func testV5ParseDomainsFromValidHTML() throws {
    let html = """
      <html><body>
      <table>
        <tr><th>Domain</th><th>Action</th></tr>
        <tr><td>doubleclick.net</td><td>Delete</td></tr>
        <tr><td>tracker.example.com</td><td>Delete</td></tr>
      </table>
      </body></html>
      """
    let entries = PiholeV5Service.parseDomainsFromHTML(html, type: 0)
    XCTAssertEqual(entries.count, 2)
    XCTAssertEqual(entries[0].domain, "doubleclick.net")
    XCTAssertEqual(entries[0].type, 0)
    XCTAssertEqual(entries[1].domain, "tracker.example.com")
    XCTAssertEqual(entries[1].type, 0)
  }

  func testV5ParseDomainsFromHTMLWithNestedTags() throws {
    let html = """
      <table>
        <tr>
          <td><strong>ads.example.com</strong></td>
          <td><a href="#">Delete</a></td>
        </tr>
        <tr>
          <td><span class="domain">spy.net</span></td>
          <td><a href="#">Delete</a></td>
        </tr>
      </table>
      """
    let entries = PiholeV5Service.parseDomainsFromHTML(html, type: 0)
    XCTAssertEqual(entries.count, 2)
    XCTAssertEqual(entries[0].domain, "ads.example.com")
    XCTAssertEqual(entries[1].domain, "spy.net")
  }

  func testV5ParseDomainsFromMalformedHTML() throws {
    let html = "<html><body><p>No table here</p></body></html>"
    let entries = PiholeV5Service.parseDomainsFromHTML(html, type: 0)
    XCTAssertTrue(entries.isEmpty)
  }

  func testV5ParseDomainsFromEmptyHTML() throws {
    let entries = PiholeV5Service.parseDomainsFromHTML("", type: 0)
    XCTAssertTrue(entries.isEmpty)
  }

  func testV5ParseDomainsFiltersHeaderRow() throws {
    let html = """
      <table>
        <tr><td>Domain</td><td>Delete</td></tr>
        <tr><td>real-domain.com</td><td>Delete</td></tr>
      </table>
      """
    let entries = PiholeV5Service.parseDomainsFromHTML(html, type: 1)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0].domain, "real-domain.com")
    XCTAssertEqual(entries[0].type, 1)
  }

  // MARK: - MockPiholeService tests

  func testMockServiceCheckStatus() async throws {
    let mock = MockPiholeService()
    mock.checkStatusStub = .success(.disabled(remainingSeconds: 30))
    let status = try await mock.checkStatus()
    XCTAssertEqual(status, .disabled(remainingSeconds: 30))
    XCTAssertEqual(mock.checkStatusCallCount, 1)
  }

  func testMockServiceSetBlocking() async throws {
    let mock = MockPiholeService()
    try await mock.setBlocking(enabled: false, duration: 300)
    XCTAssertEqual(mock.setBlockingCallCount, 1)
    XCTAssertEqual(mock.setBlockingLastEnabled, false)
    XCTAssertEqual(mock.setBlockingLastDuration, 300)
  }

  func testMockServiceAddDomain() async throws {
    let mock = MockPiholeService()
    let expected = DomainEntry(id: 99, domain: "test.com", type: 0, comment: "test-uuid")
    mock.addDomainStub = .success(expected)
    let result = try await mock.addDomain("test.com", to: .allow, comment: "test-uuid")
    XCTAssertEqual(result, expected)
    XCTAssertEqual(mock.addDomainCallCount, 1)
    XCTAssertEqual(mock.addDomainLastDomain, "test.com")
    XCTAssertEqual(mock.addDomainLastList, .allow)
    XCTAssertEqual(mock.addDomainLastComment, "test-uuid")
  }

  func testMockServiceFailureInjection() async {
    let mock = MockPiholeService()
    mock.checkStatusStub = .failure(PiholeError.unauthorized)
    do {
      _ = try await mock.checkStatus()
      XCTFail("Expected error to be thrown")
    } catch {
      XCTAssertEqual(error as? PiholeError, .unauthorized)
    }
  }

  func testMockServiceDeleteDomainByID() async throws {
    let mock = MockPiholeService()
    try await mock.deleteDomain(identifiedBy: 42)
    XCTAssertEqual(mock.deleteDomainByIDCallCount, 1)
  }

  func testMockServiceDeleteDomainByName() async throws {
    let mock = MockPiholeService()
    try await mock.deleteDomain(domain: "test.com")
    XCTAssertEqual(mock.deleteDomainByNameCallCount, 1)
  }
}
