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
      apiToken: "test-token",
      htmlParser: PiholeV5HTMLParser()
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

  @Test("checkStatus throws unauthorized when the status key is missing (unauthenticated response)")
  func checkStatusUnauthorizedWhenStatusMissing() async throws {
    // Unauthenticated v5 returns 200 {} — endpoints are gated on $auth, not HTTP status.
    mockSession.handlers = [
      { _ in
        let response = try #require(v5Response())
        return (Data(#"{}"#.utf8), response)
      }
    ]
    await #expect(throws: PiholeError.unauthorized) {
      try await makeService().checkStatus()
    }
  }

  @Test("password-less instances work with an empty api token")
  func emptyApiTokenRequests() async throws {
    let passwordlessService = PiholeV5Service(
      id: UUID(),
      label: "Open v5",
      url: "http://192.168.1.100",
      version: .v5,
      baseURL: v5BaseURL,
      session: mockSession,
      apiToken: "",
      htmlParser: PiholeV5HTMLParser()
    )
    mockSession.handlers = [
      { request in
        #expect(request.url?.query?.contains("auth=") == true, "empty token is sent as an empty auth param")
        let response = try #require(v5Response())
        return (Data(#"{"status":"enabled"}"#.utf8), response)
      }
    ]
    let status = try await passwordlessService.checkStatus()
    #expect(status == .enabled)
    #expect(await passwordlessService.isPasswordless == true)
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

  // MARK: - Auth lifecycle

  @Test("login is a no-op for token auth")
  func login() async throws {
    try await makeService().login()
  }

  @Test("logout invalidates the session")
  func logout() async {
    await makeService().logout()
    #expect(mockSession.invalidateAndCancelCallCount == 1)
  }

  // MARK: - unblockDomain

  @Test("unblockDomain adds domain to allow list")
  func unblockDomain() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.absoluteString.contains("list=white") == true)
        #expect(request.url?.absoluteString.contains("add=example.com") == true)
        let response = try #require(v5Response())
        return (Data("OK".utf8), response)
      }
    ]
    try await makeService().unblockDomain("example.com", duration: 300)
  }

  // MARK: - Error branches

  @Test("checkStatus throws on decode failure")
  func checkStatusDecodeFailure() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(v5Response())
        return (Data("not json".utf8), response)
      }
    ]
    await #expect {
      try await makeService().checkStatus()
    } throws: { error in
      guard case PiholeError.decoding = error else {
        Issue.record("Expected decoding error, got \(error)")
        return false
      }
      return true
    }
  }

  @Test("getQuerySummary throws on server error")
  func getQuerySummaryServerError() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(v5Response(statusCode: 500))
        return (Data("Error".utf8), response)
      }
    ]
    await #expect(throws: PiholeError.server(500, "Error")) {
      try await makeService().getQuerySummary()
    }
  }

  @Test("setBlocking throws on server error")
  func setBlockingServerError() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(v5Response(statusCode: 500))
        return (Data("Error".utf8), response)
      },
      { _ in
        let response = try #require(v5Response(statusCode: 500))
        return (Data("Error".utf8), response)
      }
    ]
    let service = makeService()
    await #expect(throws: PiholeError.server(500, "Error")) {
      try await service.setBlocking(enabled: true, duration: nil)
    }
    await #expect(throws: PiholeError.server(500, "Error")) {
      try await service.setBlocking(enabled: false, duration: 300)
    }
  }

  @Test("getRecentBlocked throws on server error")
  func getRecentBlockedServerError() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(v5Response(statusCode: 500))
        return (Data("Error".utf8), response)
      }
    ]
    await #expect(throws: PiholeError.server(500, "Error")) {
      try await makeService().getRecentBlocked(
        forClientIp: nil,
        interval: DateInterval(start: Date().addingTimeInterval(-3600), end: Date())
      )
    }
  }

  @Test("getRecentBlocked returns empty on malformed rows")
  func getRecentBlockedMalformedRows() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(v5Response())
        return (Data(#"{"not":"an array"}"#.utf8), response)
      }
    ]
    let blocked = try await makeService().getRecentBlocked(
      forClientIp: nil,
      interval: DateInterval(start: Date().addingTimeInterval(-3600), end: Date())
    )
    #expect(blocked.isEmpty)
  }

  @Test("getRecentBlocked passes client IP filter")
  func getRecentBlockedClientIP() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.absoluteString.contains("client=192.168.1.50") == true)
        let response = try #require(v5Response())
        return (Data("[]".utf8), response)
      }
    ]
    let blocked = try await makeService().getRecentBlocked(
      forClientIp: "192.168.1.50",
      interval: DateInterval(start: Date().addingTimeInterval(-3600), end: Date())
    )
    #expect(blocked.isEmpty)
  }

  @Test("addDomain throws on server error")
  func addDomainServerError() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(v5Response(statusCode: 500))
        return (Data("Error".utf8), response)
      }
    ]
    await #expect(throws: PiholeError.server(500, "Error")) {
      try await makeService().addDomain("example.com", to: .allow)
    }
  }

  @Test("deleteDomain throws on server error")
  func deleteDomainServerError() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(v5Response())
        return (Data("<table><tr><td>example.com</td></tr></table>".utf8), response)
      },
      { _ in
        let response = try #require(v5Response())
        return (Data("<table></table>".utf8), response)
      },
      { _ in
        let response = try #require(v5Response(statusCode: 500))
        return (Data("Error".utf8), response)
      }
    ]
    await #expect(throws: PiholeError.server(500, "Error")) {
      try await makeService().deleteDomain(domain: "example.com")
    }
  }

  @Test("getDomains skips lists that fail to fetch")
  func getDomainsListFetchFailure() async throws {
    mockSession.handlers = [
      { _ in
        // White list fetch fails with 500 → parseDomainList returns []
        let response = try #require(v5Response(statusCode: 500))
        return (Data("Error".utf8), response)
      },
      { _ in
        let response = try #require(v5Response())
        return (Data("<table><tr><td>blocked.com</td></tr></table>".utf8), response)
      }
    ]
    let domains = try await makeService().getDomains()
    #expect(domains.count == 1)
    #expect(domains[0].domain == "blocked.com")
  }

  @Test("getDomains skips lists with non-UTF8 HTML")
  func getDomainsNonUTF8HTML() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(v5Response())
        return (Data([0xFF, 0xFE, 0x80, 0x81]), response)
      },
      { _ in
        let response = try #require(v5Response())
        return (Data("<table></table>".utf8), response)
      }
    ]
    let domains = try await makeService().getDomains()
    #expect(domains.isEmpty)
  }
}
