import Foundation
import Testing

@testable import HoleberryCore

private let v5BaseURL = URL(string: "http://192.168.1.100")!

private func v5Response(statusCode: Int = 200, url: URL? = nil) -> HTTPURLResponse? {
  let url = url ?? URL(string: "http://192.168.1.100/test")!
  return HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)
}

@Suite("PiholeV5Service")
@MainActor
final class PiholeV5ServiceTests {
  private let mockSession = MockURLSession()

  private func makeService() -> PiholeV5Service {
    PiholeV5Service(
      id: UUID(),
      label: "Test v5",
      url: "http://192.168.1.100",
      version: .v5,
      baseURL: v5BaseURL,
      session: mockSession,
      apiToken: "test-token"
    )
  }

  // MARK: - checkStatus

  @Test("checkStatus returns enabled")
  func checkStatusEnabled() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.absoluteString.contains("status") == true)
        let response = try #require(v5Response())
        return (Data(#"{"status":"enabled"}"#.utf8), response)
      }
    ]
    let status = try await makeService().checkStatus()
    #expect(status == .enabled)
  }

  @Test("checkStatus returns disabled")
  func checkStatusDisabled() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(v5Response())
        return (Data(#"{"status":"disabled"}"#.utf8), response)
      }
    ]
    let status = try await makeService().checkStatus()
    #expect(status == .disabled(remainingSeconds: nil))
  }

  @Test("checkStatus throws on server error")
  func checkStatusServerError() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(v5Response(statusCode: 500))
        return (Data("Internal Error".utf8), response)
      }
    ]
    await #expect(throws: PiholeError.server(500, "Internal Error")) {
      try await makeService().checkStatus()
    }
  }

  // MARK: - setBlocking

  @Test("setBlocking enables")
  func setBlockingEnable() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.absoluteString.contains("enable") == true)
        let response = try #require(v5Response())
        return (Data("OK".utf8), response)
      }
    ]
    try await makeService().setBlocking(enabled: true, duration: nil)
  }

  @Test("setBlocking disables with duration")
  func setBlockingDisableWithDuration() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.absoluteString.contains("disable") == true)
        #expect(request.url?.absoluteString.contains("300") == true)
        let response = try #require(v5Response())
        return (Data("OK".utf8), response)
      }
    ]
    try await makeService().setBlocking(enabled: false, duration: 300)
  }

  // MARK: - getQuerySummary

  @Test("getQuerySummary parses v5 response")
  func getQuerySummary() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.absoluteString.contains("summaryRaw") == true)
        let response = try #require(v5Response())
        let data = Data(#"{"queries_total":"1500","ads_blocked_today":"75"}"#.utf8)
        return (data, response)
      }
    ]
    let summary = try await makeService().getQuerySummary()
    #expect(summary.totalQueries == 1500)
    #expect(summary.totalBlocked == 75)
  }

  @Test("getQuerySummary throws on missing keys")
  func getQuerySummaryMissingKeys() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(v5Response())
        let data = Data(#"{"other":"data"}"#.utf8)
        return (data, response)
      }
    ]
    await #expect(throws: PiholeError.decoding("Unexpected summary format: {\"other\":\"data\"}")) {
      try await makeService().getQuerySummary()
    }
  }

  // MARK: - getRecentBlocked

  @Test("getRecentBlocked filters blocked queries")
  func getRecentBlocked() async throws {
    let now = Date()
    let interval = DateInterval(start: now.addingTimeInterval(-3600), end: now)

    mockSession.handlers = [
      { request in
        let urlStr = request.url?.absoluteString ?? ""
        #expect(urlStr.contains("getAllQueries"))
        let from = Int(now.addingTimeInterval(-3600).timeIntervalSince1970)
        let until = Int(now.timeIntervalSince1970)
        #expect(urlStr.contains("from=\(from)") || urlStr.contains("until=\(until)"))
        let response = try #require(v5Response())
        let timestamp1 = now.addingTimeInterval(-1800).timeIntervalSince1970
        let timestamp2 = now.addingTimeInterval(-900).timeIntervalSince1970
        let timestamp3 = now.addingTimeInterval(-300).timeIntervalSince1970
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let ts1 = dateFormatter.string(from: Date(timeIntervalSince1970: timestamp1))
        let ts2 = dateFormatter.string(from: Date(timeIntervalSince1970: timestamp2))
        let ts3 = dateFormatter.string(from: Date(timeIntervalSince1970: timestamp3))
        let json =
          "[[\"\(ts1)\",\"A\",\"blocked.com\",\"192.168.1.5\"," + "\"1\",\"Blocked\",\"0\"],"
          + "[\"\(ts2)\",\"A\",\"allowed.com\",\"192.168.1.5\"," + "\"2\",\"OK\",\"0\"],"
          + "[\"\(ts3)\",\"A\",\"tracker.net\",\"192.168.1.10\"," + "\"1\",\"Blocked\",\"0\"]]"
        return (Data(json.utf8), response)
      }
    ]
    let blocked = try await makeService().getRecentBlocked(forClientIp: nil, interval: interval)
    #expect(blocked.count == 2)
    #expect(blocked[0].domain == "blocked.com")
    #expect(blocked[1].domain == "tracker.net")
  }

  // MARK: - addDomain / deleteDomain

  @Test("addDomain calls API with list param")
  func addDomain() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.absoluteString.contains("list=white") == true)
        #expect(request.url?.absoluteString.contains("add=example.com") == true)
        let response = try #require(v5Response())
        return (Data("OK".utf8), response)
      }
    ]
    let entry = try await makeService().addDomain("example.com", to: .allow)
    #expect(entry.domain == "example.com")
  }

  @Test("deleteDomain fetches domains then deletes")
  func deleteDomain() async throws {
    mockSession.handlers = [
      { _ in
        // First parseDomainList call (white list) — contains the domain
        let response = try #require(v5Response())
        let html = """
          <table><tr><td>example.com</td></tr></table>
          """
        return (Data(html.utf8), response)
      },
      { _ in
        // Second parseDomainList call (black list) — empty
        let response = try #require(v5Response())
        return (Data("<table></table>".utf8), response)
      },
      { request in
        // Actual delete call
        #expect(request.url?.absoluteString.contains("sub=example.com") == true)
        let response = try #require(v5Response())
        return (Data("OK".utf8), response)
      }
    ]
    try await makeService().deleteDomain(domain: "example.com")
    #expect(mockSession.requests.count == 3)
  }
}
