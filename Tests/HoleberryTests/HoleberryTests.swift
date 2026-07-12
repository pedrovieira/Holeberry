import Defaults
import XCTest

@testable import Holeberry

// swiftlint:disable file_length

@MainActor
final class HoleberryTests: XCTestCase {
  /// Throwaway UserDefaults suite — no test data touches the real UserDefaults.standard.
  private let testUserDefaults: UserDefaults = {
    guard let defaults = UserDefaults(suiteName: "com.holeberry.tests") else {
      fatalError("Failed to create test UserDefaults suite")
    }
    return defaults
  }()

  override func setUp() {
    super.setUp()
    testUserDefaults.removePersistentDomain(forName: "com.holeberry.tests")
  }

  override func tearDown() {
    testUserDefaults.removePersistentDomain(forName: "com.holeberry.tests")
    super.tearDown()
  }

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
    XCTAssertEqual(PiholeError.unauthorized.errorDescription, "Authentication failed. Check your credential.")
    XCTAssertEqual(PiholeError.network("timeout").errorDescription, "Network error: timeout")
    XCTAssertEqual(PiholeError.server(500, nil).errorDescription, "Server error (500)")
    XCTAssertEqual(
      PiholeError.server(500, "Internal Server Error").errorDescription,
      "Server error (500): Internal Server Error")
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
    let json = "{\"blocking\": true}"
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
    let json = "{\"blocking\": false, \"timer\": 180.0}"
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
    let json = "{\"blocked\": [\"doubleclick.net\", \"ads.com\", \"tracker.example.com\"]}"
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
    let json =
      "{\"id\": 42, \"domain\": \"example.com\", \"type\": 0, \"comment\": \"via holeberryapp.com / test-uuid\"}"
    let data = try XCTUnwrap(json.data(using: .utf8))
    let entry = try JSONDecoder().decode(DomainEntry.self, from: data)
    XCTAssertEqual(entry.id, 42)
    XCTAssertEqual(entry.domain, "example.com")
    XCTAssertEqual(entry.type, 0)
    XCTAssertEqual(entry.comment, "via holeberryapp.com / test-uuid")
  }

  func testV6DomainsResponseDecoding() throws {
    // Pi-hole v6 wraps domains in {"domains":[...]} with string type values.
    let json =
      "{\"domains\":["
      + "{\"domain\":\"a.com\",\"type\":\"allow\",\"comment\":\"\"},"
      + "{\"domain\":\"b.com\",\"type\":\"deny\",\"comment\":\"x\"}]}"
    let data = try XCTUnwrap(json.data(using: .utf8))
    let response = try JSONDecoder().decode(DomainsResponse.self, from: data)
    XCTAssertEqual(response.domains.count, 2)
    XCTAssertEqual(response.domains[0].domain, "a.com")
    XCTAssertEqual(response.domains[0].type, 0)
    XCTAssertEqual(response.domains[1].domain, "b.com")
    XCTAssertEqual(response.domains[1].type, 1)
    XCTAssertEqual(response.domains[1].comment, "x")
  }

  func testV6DomainsResponseDecodingIntegerTypes() throws {
    // Also accept integer type values (v5-compatible format).
    let json =
      "[{\"id\": 1, \"domain\": \"allowed.com\", \"type\": 0, \"comment\": \"\"}, "
      + "{\"id\": 2, \"domain\": \"blocked.com\", \"type\": 1, \"comment\": \"manual block\"}]"
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
    let json = "{\"status\": \"enabled\"}"
    let data = try XCTUnwrap(json.data(using: .utf8))
    struct StatusResponse: Decodable {
      let status: String?
    }
    let status = try JSONDecoder().decode(StatusResponse.self, from: data)
    XCTAssertEqual(status.status, "enabled")
  }

  func testV5CheckStatusDisabledDecoding() throws {
    let json = "{\"status\": \"disabled\"}"
    let data = try XCTUnwrap(json.data(using: .utf8))
    struct StatusResponse: Decodable {
      let status: String?
    }
    let status = try JSONDecoder().decode(StatusResponse.self, from: data)
    XCTAssertEqual(status.status, "disabled")
  }

  func testV5GetAllQueriesDecoding() throws {
    let json =
      "[[\"2024-01-15 10:30:00\", \"A\", \"example.com\", \"192.168.1.5\", \"2\", \"OK\", \"0\"], "
      + "[\"2024-01-15 10:31:00\", \"AAAA\", \"blocked.com\", \"192.168.1.10\", \"1\", \"Blocked\", \"1\"], "
      + "[\"2024-01-15 10:32:00\", \"A\", \"tracker.net\", \"192.168.1.5\", \"1\", \"Blocked\", \"1\"]]"
    let data = try XCTUnwrap(json.data(using: .utf8))
    guard let rawJSON = try JSONSerialization.jsonObject(with: data) as? [[Any]] else {
      XCTFail("Expected array of arrays")
      return
    }

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

    let blockedStatuses: Set<String> = ["1", "4", "5", "6"]

    let blocked: [BlockedDomain] = rawJSON.compactMap { row -> BlockedDomain? in
      guard row.count >= 5 else { return nil }
      let status = "\(row[4])"
      guard blockedStatuses.contains(status) else { return nil }
      let domain = "\(row[2])"
      let client = "\(row[3])"
      let timestamp = dateFormatter.date(from: "\(row[0])") ?? Date()
      return BlockedDomain(domain: domain, timestamp: timestamp, fromClientIp: client)
    }

    XCTAssertEqual(blocked.count, 2)
    XCTAssertEqual(blocked[0].domain, "blocked.com")
    XCTAssertEqual(blocked[1].domain, "tracker.net")
  }

  // MARK: - v5 HTML parsing tests

  func testV5ParseDomainsFromValidHTML() throws {
    let html =
      "<html><body><table>"
      + "<tr><th>Domain</th><th>Action</th></tr>"
      + "<tr><td>doubleclick.net</td><td>Delete</td></tr>"
      + "<tr><td>tracker.example.com</td><td>Delete</td></tr>"
      + "</table></body></html>"
    let entries = PiholeV5Service.parseDomainsFromHTML(html, type: 0)
    XCTAssertEqual(entries.count, 2)
    XCTAssertEqual(entries[0].domain, "doubleclick.net")
    XCTAssertEqual(entries[0].type, 0)
    XCTAssertEqual(entries[1].domain, "tracker.example.com")
    XCTAssertEqual(entries[1].type, 0)
  }

  func testV5ParseDomainsFromHTMLWithNestedTags() throws {
    let html =
      "<table>"
      + "<tr><td><strong>ads.example.com</strong></td><td><a href=\"#\">Delete</a></td></tr>"
      + "<tr><td><span class=\"domain\">spy.net</span></td><td><a href=\"#\">Delete</a></td></tr>"
      + "</table>"
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
    let html =
      "<table>"
      + "<tr><td>Domain</td><td>Delete</td></tr>"
      + "<tr><td>real-domain.com</td><td>Delete</td></tr>"
      + "</table>"
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

  func testMockServiceDeleteDomainByName() async throws {
    let mock = MockPiholeService()
    try await mock.deleteDomain(domain: "test.com")
    XCTAssertEqual(mock.deleteDomainByNameCallCount, 1)
  }

  // MARK: - ServerConfig tests

  func testServerConfigDefaults() {
    let server = ServerConfig(label: nil, url: "http://192.168.1.100:80", version: .v6)
    XCTAssertFalse(server.id.uuidString.isEmpty)
    XCTAssertNil(server.label)
    XCTAssertEqual(server.url, "http://192.168.1.100:80")
    XCTAssertEqual(server.version, .v6)
  }

  func testServerConfigWithLabel() {
    let server = ServerConfig(label: "Home", url: "https://pihole.local:443", version: .v6)
    XCTAssertEqual(server.label, "Home")
    XCTAssertEqual(server.url, "https://pihole.local:443")
  }

  func testServerConfigVersionAfterDetection() {
    var server = ServerConfig(label: nil, url: "http://192.168.1.100", version: .v5)
    server.version = .v6
    XCTAssertEqual(server.version, .v6)
  }

  func testServerConfigEquality() {
    let id = UUID()
    let server1 = ServerConfig(id: id, label: "A", url: "http://a.com", version: .v6)
    let server2 = ServerConfig(id: id, label: "B", url: "http://b.com", version: .v6)
    XCTAssertEqual(server1, server2)  // equal by id
  }

  func testServerConfigCodableRoundTrip() throws {
    let server = ServerConfig(label: "Test", url: "http://test.com:8080", version: .v6)
    let data = try JSONEncoder().encode(server)
    let decoded = try JSONDecoder().decode(ServerConfig.self, from: data)
    XCTAssertEqual(server.id, decoded.id)
    XCTAssertEqual(server.label, decoded.label)
    XCTAssertEqual(server.url, decoded.url)
    XCTAssertEqual(server.version, decoded.version)
  }

  func testServerConfigCodableNilLabel() throws {
    let server = ServerConfig(label: nil, url: "http://test.com", version: .v5)
    let data = try JSONEncoder().encode(server)
    let decoded = try JSONDecoder().decode(ServerConfig.self, from: data)
    XCTAssertNil(decoded.label)
    XCTAssertEqual(decoded.version, .v5)
  }

  // MARK: - Defaults persistence tests

  func testDefaultsServersEmptyByDefault() {
    let data = testUserDefaults.data(forKey: "servers")
    XCTAssertNil(data)
  }

  func testDefaultsServersSaveAndLoad() throws {
    let encoder = JSONEncoder()
    let server = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    let data = try encoder.encode([server])
    testUserDefaults.set(data, forKey: "servers")

    let loadedData = try XCTUnwrap(testUserDefaults.data(forKey: "servers"))
    let loaded = try JSONDecoder().decode([ServerConfig].self, from: loadedData)
    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded[0].id, server.id)
    XCTAssertEqual(loaded[0].url, "http://test.com")
  }

  func testDefaultsServersOverwrite() throws {
    let encoder = JSONEncoder()
    let server1 = ServerConfig(label: "A", url: "http://a.com", version: .v6)
    let server2 = ServerConfig(label: "B", url: "http://b.com", version: .v6)
    testUserDefaults.set(try encoder.encode([server1]), forKey: "servers")
    testUserDefaults.set(try encoder.encode([server2]), forKey: "servers")

    let data = try XCTUnwrap(testUserDefaults.data(forKey: "servers"))
    let loaded = try JSONDecoder().decode([ServerConfig].self, from: data)
    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded[0].id, server2.id)
  }

  func testDefaultsServersMultiple() throws {
    let encoder = JSONEncoder()
    let server1 = ServerConfig(label: "A", url: "http://a.com", version: .v6)
    let server2 = ServerConfig(label: "B", url: "http://b.com", version: .v6)
    testUserDefaults.set(try encoder.encode([server1, server2]), forKey: "servers")

    let data = try XCTUnwrap(testUserDefaults.data(forKey: "servers"))
    let loaded = try JSONDecoder().decode([ServerConfig].self, from: data)
    XCTAssertEqual(loaded.count, 2)
  }

  func testDefaultsServersCorruptedData() {
    testUserDefaults.set("<bad json>", forKey: "servers")
    // PiholeServerManager uses a key bound to the injected suite — corrupted data = empty.
    let manager = PiholeServerManager(suite: testUserDefaults)
    XCTAssertTrue(manager.servers.isEmpty)
  }

  // MARK: - PiholeServerManager tests

  func testManagerStartsEmpty() {
    let manager = PiholeServerManager(suite: testUserDefaults)
    XCTAssertTrue(manager.servers.isEmpty)
  }

  func testManagerDeleteServer() {
    let manager = PiholeServerManager(suite: testUserDefaults)
    let server = ServerConfig(label: "Test", url: "http://test.com", version: .v6)
    manager.servers = [server]
    let id = manager.servers[0].id
    manager.deleteServer(id: id)
    XCTAssertTrue(manager.servers.isEmpty)
  }

  func testManagerUpdateServer() {
    let manager = PiholeServerManager(suite: testUserDefaults)
    let server = ServerConfig(label: "Old", url: "http://old.com", version: .v6)
    manager.servers = [server]
    guard let id = manager.servers.first?.id else { return XCTFail("No server") }

    manager.updateServer(id: id, label: "New", url: "http://new.com", credential: nil)
    XCTAssertEqual(manager.servers[0].label, "New")
    XCTAssertEqual(manager.servers[0].url, "http://new.com")
  }

  // MARK: - TempUnblockRecord tests

  func testTempUnblockRecordCodableRoundTrip() throws {
    let record = TempUnblockRecord(
      domain: "doubleclick.net",
      uuid: "via holeberryapp.com / test-uuid",
      startDateUTC: Date(),
      durationSeconds: 300,
      pendingRemoval: true,
      retryCount: 2
    )
    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(TempUnblockRecord.self, from: data)
    XCTAssertEqual(decoded.domain, record.domain)
    XCTAssertEqual(decoded.uuid, record.uuid)
    XCTAssertEqual(decoded.durationSeconds, record.durationSeconds)
    XCTAssertEqual(decoded.pendingRemoval, record.pendingRemoval)
    XCTAssertEqual(decoded.retryCount, record.retryCount)
    XCTAssertLessThan(abs(decoded.startDateUTC.timeIntervalSince(record.startDateUTC)), 0.001)
  }

  func testTempUnblockRecordDefaults() {
    let record = TempUnblockRecord(
      domain: "ads.com",
      uuid: "via holeberryapp.com / uuid-2",
      startDateUTC: Date(),
      durationSeconds: 60
    )
    XCTAssertFalse(record.pendingRemoval)
    XCTAssertEqual(record.retryCount, 0)
  }
}
