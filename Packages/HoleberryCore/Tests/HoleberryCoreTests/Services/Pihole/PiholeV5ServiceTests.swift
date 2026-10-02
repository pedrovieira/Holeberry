import Defaults
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
      apiToken: ""
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
        let data = Data(
          #"{"dns_queries_today":1500.0,"ads_blocked_today":75.0,"gravity_last_updated":{"file_exists":true,"absolute":1726223567,"relative":{"days":2,"hours":3,"minutes":4}}}"#
            .utf8)
        return (data, response)
      }
    ]
    let summary = try await makeService().getQuerySummary()
    #expect(summary.totalQueries == 1500)
    #expect(summary.totalBlocked == 75)
    #expect(summary.gravityLastUpdated == Date(timeIntervalSince1970: 1_726_223_567))
  }

  @Test("getQuerySummary returns nil gravity date when file missing")
  func getQuerySummaryGravityFileMissing() async throws {
    mockSession.handlers = [
      { request in
        let response = try #require(v5Response())
        let data = Data(
          #"{"dns_queries_today":1500.0,"ads_blocked_today":75.0,"gravity_last_updated":{"file_exists":false}}"#.utf8)
        return (data, response)
      }
    ]
    let summary = try await makeService().getQuerySummary()
    #expect(summary.gravityLastUpdated == nil)
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

  // MARK: - updateGravity

  @Test("updateGravity is unsupported on v5")
  func updateGravityUnsupported() async {
    await #expect(throws: PiholeError.unsupported("Gravity updates via API are not supported by Pi-hole v5")) {
      try await makeService().updateGravity()
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
          "{\"data\":[[\"\(ts1)\",\"A\",\"blocked.com\",\"192.168.1.5\"," + "\"1\",\"Blocked\",\"0\"],"
          + "[\"\(ts2)\",\"A\",\"allowed.com\",\"192.168.1.5\"," + "\"2\",\"OK\",\"0\"],"
          + "[\"\(ts3)\",\"A\",\"tracker.net\",\"192.168.1.10\"," + "\"1\",\"Blocked\",\"0\"]]}"
        return (Data(json.utf8), response)
      }
    ]
    let blocked = try await makeService().getRecentBlocked(forClientIp: nil, interval: interval)
    #expect(blocked.count == 2)
    #expect(blocked[0].domain == "blocked.com")
    #expect(blocked[1].domain == "tracker.net")
  }

  // MARK: - addDomain / deleteDomain

  @Test("addDomain leaves a pre-existing entry alone")
  func addDomainHit() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.absoluteString.contains("list=white") == true)
        let response = try #require(v5Response())
        let json = #"{"data":[{"id":1,"domain":"example.com","type":0,"enabled":1,"comment":null,"groups":[0]}]}"#
        return (Data(json.utf8), response)
      }
    ]
    let outcome = try await makeService().addDomain(
      "Example.COM", to: .allow, comment: "uuid"
    )
    #expect(outcome == .alreadyPresent)
    #expect(mockSession.requests.count == 1, "Nothing is added, so the list read is the only request")
  }

  @Test(
    "addDomain matches an international entry by its punycode identity",
    arguments: ["xn--bcher-kva.de", "shop.xn--bcher-kva.de", "example.xn--p1ai"]
  )
  func addDomainMatchesIDN(domain: String) async throws {
    mockSession.handlers = [
      { _ in
        let displayDomain = "international.example (\(domain))"
        let json = """
          {"data":[{"id":1,"domain":"\(displayDomain)","type":0,"enabled":1,"comment":null,"groups":[0]}]}
          """
        return (Data(json.utf8), try #require(v5Response()))
      }
    ]
    let outcome = try await makeService().addDomain(
      domain, to: .allow, comment: "uuid"
    )
    #expect(outcome == .alreadyPresent)
    #expect(mockSession.requests.count == 1)
  }

  @Test("addDomain adds an entry that is not there")
  func addDomainMiss() async throws {
    mockSession.handlers = [
      { _ in (Data(#"{"data":[]}"#.utf8), try #require(v5Response())) },
      { request in
        #expect(request.url?.absoluteString.contains("list=white") == true)
        #expect(request.url?.absoluteString.contains("add=example.com") == true)
        return (Data(#"{"success":true,"message":"Added example.com"}"#.utf8), try #require(v5Response()))
      }
    ]
    let outcome = try await makeService().addDomain(
      "example.com", to: .allow, comment: "uuid"
    )
    #expect(outcome == .added)
    #expect(mockSession.requests.count == 2, "The list read is followed by the add")
  }

  @Test("deleteDomain targets the allow list")
  func deleteDomainTargetsAllowList() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.absoluteString.contains("list=white") == true)
        #expect(request.url?.absoluteString.contains("list=black") == false)
        #expect(request.url?.absoluteString.contains("sub=example.com") == true)
        let response = try #require(v5Response())
        return (Data(#"{"success":true}"#.utf8), response)
      }
    ]
    try await makeService().deleteDomain("example.com", from: .allow)
  }

  @Test("deleteDomain targets the deny list")
  func deleteDomainTargetsDenyList() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.absoluteString.contains("list=black") == true)
        #expect(request.url?.absoluteString.contains("sub=ads.example") == true)
        let response = try #require(v5Response())
        return (Data(#"{"success":true}"#.utf8), response)
      }
    ]
    try await makeService().deleteDomain("ads.example", from: .deny)
  }

  @Test("Domain writes reject HTTP 200 operation failures", arguments: [true, false])
  func domainMutationRejected(adding: Bool) async throws {
    // JSON_error adds an action object under the numeric key "0".
    let body = #"{"success":false,"message":"database is locked","0":{"action":"add_domain"}}"#
    if adding {
      mockSession.handlers.append { _ in
        (Data(#"{"data":[]}"#.utf8), try #require(v5Response()))
      }
    }
    mockSession.handlers.append { _ in (Data(body.utf8), try #require(v5Response())) }

    await #expect(throws: PiholeError.server(200, "database is locked")) {
      if adding {
        _ = try await makeService().addDomain("example.com", to: .allow, comment: nil)
      } else {
        try await makeService().deleteDomain("example.com", from: .allow)
      }
    }
  }

  @Test("Domain writes reject failure replies without a message", arguments: [true, false])
  func domainMutationRejectedWithoutMessage(adding: Bool) async throws {
    if adding {
      mockSession.handlers.append { _ in
        (Data(#"{"data":[]}"#.utf8), try #require(v5Response()))
      }
    }
    mockSession.handlers.append { _ in
      (Data(#"{"success":false,"message":null}"#.utf8), try #require(v5Response()))
    }

    await #expect(throws: PiholeError.server(200, nil)) {
      if adding {
        _ = try await makeService().addDomain("example.com", to: .allow, comment: nil)
      } else {
        try await makeService().deleteDomain("example.com", from: .allow)
      }
    }
  }

  @Test(
    "Domain writes reject malformed or unconfirmed replies",
    arguments: [true, false],
    ["", "Not authorized!", "{}", #"{"success":null}"#, #"{"success":"true"}"#]
  )
  func domainMutationMalformed(adding: Bool, body: String) async throws {
    if adding {
      mockSession.handlers.append { _ in
        (Data(#"{"data":[]}"#.utf8), try #require(v5Response()))
      }
    }
    mockSession.handlers.append { _ in (Data(body.utf8), try #require(v5Response())) }

    await #expect {
      if adding {
        _ = try await makeService().addDomain("example.com", to: .allow, comment: nil)
      } else {
        try await makeService().deleteDomain("example.com", from: .allow)
      }
    } throws: { error in
      guard case PiholeError.decoding = error else { return false }
      return true
    }
  }

  @Test("A rejected v5 add does not create a temporary-unblock record")
  func rejectedAddIsNotTracked() async throws {
    mockSession.handlers = [
      { _ in (Data(#"{"data":[]}"#.utf8), try #require(v5Response())) },
      { _ in
        (Data(#"{"success":false,"message":"database is locked"}"#.utf8), try #require(v5Response()))
      }
    ]
    let service = makeService()
    let suite = TestDefaults.makeSuite()
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: service, defaultsSuite: suite) { _ in }

    await #expect(throws: PiholeError.server(200, "database is locked")) {
      try await decorator.unblockDomain("example.com", duration: 60)
    }
    #expect(Defaults[.tempUnblocks(for: service.id, suite: suite)].isEmpty)
    #expect(mockSession.requests.count == 3, "An add error triggers one ownership lookup")
  }

  @Test("A rejected v5 expiry delete keeps its record and retries")
  func rejectedExpiryDeletionRetries() async throws {
    mockSession.handlers = [
      { _ in (Data(#"{"data":[]}"#.utf8), try #require(v5Response())) },
      { _ in (Data(#"{"success":true,"message":"Added example.com"}"#.utf8), try #require(v5Response())) },
      { _ in
        (Data(#"{"success":false,"message":"database is locked"}"#.utf8), try #require(v5Response()))
      },
      { _ in (Data(#"{"success":true,"message":null}"#.utf8), try #require(v5Response())) }
    ]
    let service = makeService()
    let suite = TestDefaults.makeSuite()
    var releaseRetry = false
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: service, defaultsSuite: suite) { duration in
      if duration < 10 { return }
      await waitUntil { releaseRetry }
    }
    try await decorator.unblockDomain("example.com", duration: 1)

    let key = Defaults.Keys.tempUnblocks(for: service.id, suite: suite)
    await waitUntil { Defaults[key].first?.pendingRemoval == true }
    #expect(Defaults[key].count == 1)
    #expect(Defaults[key].first?.retryCount == 1)
    #expect(mockSession.requests.count == 3)

    releaseRetry = true
    await waitUntil { Defaults[key].isEmpty }
    #expect(mockSession.requests.count == 4)
  }

  @Test("getDomains(from:) reads the matching list")
  func getDomainsFromList() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.absoluteString.contains("list=white") == true)
        let response = try #require(v5Response())
        let json = #"{"data":[{"id":1,"domain":"example.com","type":0,"enabled":1,"comment":null,"groups":[0]}]}"#
        return (Data(json.utf8), response)
      },
      { request in
        #expect(request.url?.absoluteString.contains("list=black") == true)
        let response = try #require(v5Response())
        let json = #"{"data":[{"id":2,"domain":"ads.example","type":1,"enabled":1,"comment":"manual","groups":[0]}]}"#
        return (Data(json.utf8), response)
      }
    ]
    let allow = try await makeService().getDomains(from: .allow)
    #expect(allow.map(\.domain) == ["example.com"])
    #expect(allow[0].enabled == true)
    let deny = try await makeService().getDomains(from: .deny)
    #expect(deny.map(\.domain) == ["ads.example"])
    #expect(deny[0].comment == "manual")
  }

  @Test("getDomains(from:) reduces an international entry to its punycode identity")
  func getDomainsNormalizesIDN() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.absoluteString.contains("list=white") == true)
        let response = try #require(v5Response())
        // web v5.21 formats an international entry as the unicode form,
        // HTML-escaped, with the ASCII name in parentheses (groups.php).
        let json = #"""
          {"data":[{"id":1,"domain":"b&uuml;cher.de (xn--bcher-kva.de)","type":0,"enabled":1,"comment":null,"groups":[0]}]}
          """#
        return (Data(json.utf8), response)
      }
    ]
    let allow = try await makeService().getDomains(from: .allow)
    #expect(allow.map(\.domain) == ["xn--bcher-kva.de"])
  }

  @Test("getDomains(from:) throws when a list fetch fails")
  func getDomainsThrowsOnFetchFailure() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(v5Response(statusCode: 500))
        return (Data("Error".utf8), response)
      }
    ]
    await #expect(throws: PiholeError.server(500, "Error")) {
      try await makeService().getDomains(from: .allow)
    }
  }

  @Test("getDomains(from:) throws a decoding error on a malformed body")
  func getDomainsThrowsOnMalformedBody() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(v5Response())
        return (Data([0xFF, 0xFE, 0x80, 0x81]), response)
      }
    ]
    await #expect {
      try await makeService().getDomains(from: .deny)
    } throws: { error in
      guard case PiholeError.decoding = error else {
        Issue.record("Expected decoding error, got \(error)")
        return false
      }
      return true
    }
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
      { _ in (Data(#"{"data":[]}"#.utf8), try #require(v5Response())) },
      { request in
        #expect(request.url?.absoluteString.contains("list=white") == true)
        #expect(request.url?.absoluteString.contains("add=example.com") == true)
        let response = try #require(v5Response())
        return (Data(#"{"success":true,"message":"Added example.com"}"#.utf8), response)
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
        return (Data(#"{"data":[]}"#.utf8), response)
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
      { _ in (Data(#"{"data":[]}"#.utf8), try #require(v5Response())) },
      { _ in
        let response = try #require(v5Response(statusCode: 500))
        return (Data("Error".utf8), response)
      }
    ]
    await #expect(throws: PiholeError.server(500, "Error")) {
      try await makeService().addDomain("example.com", to: .allow, comment: nil)
    }
  }

  @Test("addDomain propagates list probe failure without writing")
  func addDomainProbeFailure() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.absoluteString.contains("add=") == false)
        return (Data("Error".utf8), try #require(v5Response(statusCode: 500)))
      }
    ]
    await #expect(throws: PiholeError.server(500, "Error")) {
      try await makeService().addDomain("example.com", to: .allow, comment: nil)
    }
    #expect(mockSession.requests.count == 1)
  }

  @Test("deleteDomain throws on server error")
  func deleteDomainServerError() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(v5Response(statusCode: 500))
        return (Data("Error".utf8), response)
      }
    ]
    await #expect(throws: PiholeError.server(500, "Error")) {
      try await makeService().deleteDomain("example.com", from: .allow)
    }
  }
}
