import Foundation
import Testing

@testable import Holeberry

private func v6Response(statusCode: Int = 200) -> HTTPURLResponse? {
  let url = URL(string: "http://192.168.1.100/test")!
  return HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)
}

@Suite("PiholeV6Service")
@MainActor
final class PiholeV6ServiceTests {
  private let mockSession = MockURLSession()

  private func makeService(authSession: AuthSessionProviding? = nil) -> PiholeV6Service {
    let mockAuth = authSession ?? MockAuthSessionProvider()
    return PiholeV6Service(
      id: UUID(),
      label: "Test v6",
      url: "http://192.168.1.100",
      version: .v6,
      baseURL: URL(string: "http://192.168.1.100")!,
      urlSession: mockSession,
      authSession: mockAuth
    )
  }

  // MARK: - checkStatus

  @Test("checkStatus returns enabled")
  func checkStatusEnabled() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/dns/blocking")
        #expect(request.httpMethod == "GET")
        let response = try #require(v6Response())
        return (Data(#"{"blocking":"enabled"}"#.utf8), response)
      }
    ]
    let status = try await makeService().checkStatus()
    #expect(status == .enabled)
    #expect(mockSession.requests.count == 1)
  }

  @Test("checkStatus returns disabled with timer")
  func checkStatusDisabledWithTimer() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/dns/blocking")
        #expect(request.httpMethod == "GET")
        let response = try #require(v6Response())
        return (Data(#"{"blocking":"disabled","timer":180.0}"#.utf8), response)
      }
    ]
    let status = try await makeService().checkStatus()
    #expect(status == .disabled(remainingSeconds: 180.0))
  }

  @Test("checkStatus returns disabled without timer when missing")
  func checkStatusDisabledNoTimer() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/dns/blocking")
        #expect(request.httpMethod == "GET")
        let response = try #require(v6Response())
        return (Data(#"{"blocking":"disabled"}"#.utf8), response)
      }
    ]
    let status = try await makeService().checkStatus()
    #expect(status == .disabled(remainingSeconds: nil))
  }

  @Test("checkStatus throws on server error")
  func checkStatusServerError() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/dns/blocking")
        #expect(request.httpMethod == "GET")
        let response = try #require(v6Response(statusCode: 500))
        return (Data("Internal Server Error".utf8), response)
      }
    ]
    await #expect(throws: PiholeError.server(500, "Internal Server Error")) {
      try await makeService().checkStatus()
    }
  }

  @Test("checkStatus throws on malformed JSON")
  func checkStatusMalformedJSON() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/dns/blocking")
        #expect(request.httpMethod == "GET")
        let response = try #require(v6Response())
        return (Data("{bad json}".utf8), response)
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

  // MARK: - setBlocking

  @Test("setBlocking enables")
  func setBlockingEnable() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/dns/blocking")
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["blocking"] as? Bool == true)
        #expect(json?["timer"] == nil)
        let response = try #require(v6Response())
        return (Data(#"{"blocking":true}"#.utf8), response)
      }
    ]
    try await makeService().setBlocking(enabled: true, duration: nil)
  }

  @Test("setBlocking disables with duration")
  func setBlockingDisableWithDuration() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/dns/blocking")
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["blocking"] as? Bool == false)
        #expect(json?["timer"] as? Int == 300)
        let response = try #require(v6Response())
        return (Data(#"{"blocking":false,"timer":300}"#.utf8), response)
      }
    ]
    try await makeService().setBlocking(enabled: false, duration: 300)
  }

  @Test("setBlocking disables indefinitely")
  func setBlockingDisableIndefinitely() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/dns/blocking")
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["blocking"] as? Bool == false)
        #expect(json?["timer"] == nil)
        let response = try #require(v6Response())
        return (Data(#"{"blocking":false}"#.utf8), response)
      }
    ]
    try await makeService().setBlocking(enabled: false, duration: nil)
  }


  // MARK: - getQuerySummary

  @Test("getQuerySummary decodes v6 format")
  func getQuerySummary() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/stats/summary")
        #expect(request.httpMethod == "GET")
        let response = try #require(v6Response())
        let data = Data(#"{"queries":{"total":5000,"blocked":250,"cached":1000,"forwarded":3750}}"#.utf8)
        return (data, response)
      }
    ]
    let summary = try await makeService().getQuerySummary()
    #expect(summary.totalQueries == 5000)
    #expect(summary.totalBlocked == 250)
  }

  @Test("getQuerySummary throws on missing keys")
  func getQuerySummaryMissingKeys() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/stats/summary")
        #expect(request.httpMethod == "GET")
        let response = try #require(v6Response())
        return (Data(#"{"other":"data"}"#.utf8), response)
      }
    ]
    await #expect {
      try await makeService().getQuerySummary()
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
      { request in
        #expect(request.url?.path == "/api/stats/summary")
        #expect(request.httpMethod == "GET")
        let response = try #require(v6Response(statusCode: 500))
        return (Data("Error".utf8), response)
      }
    ]
    await #expect(throws: PiholeError.server(500, "Error")) {
      try await makeService().getQuerySummary()
    }
  }

  // MARK: - addDomain

  @Test("addDomain posts to v6 API")
  func addDomain() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/domains/allow/exact")
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["domain"] as? String == "example.com")
        let response = try #require(v6Response())
        let data = Data(#"{"domains":[{"id":1,"domain":"example.com","type":"allow","comment":""}]}"#.utf8)
        return (data, response)
      }
    ]
    let entry = try await makeService().addDomain("example.com", to: .allow)
    #expect(entry.domain == "example.com")
    #expect(entry.type == 0)
  }

  @Test("addDomain throws duplicateDomain on 409")
  func addDomainDuplicate() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/domains/allow/exact")
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["domain"] as? String == "dupe.com")
        let response = try #require(v6Response(statusCode: 409))
        return (Data("Conflict".utf8), response)
      }
    ]
    await #expect(throws: PiholeError.duplicateDomain) {
      try await makeService().addDomain("dupe.com", to: .allow)
    }
  }


  // MARK: - deleteDomain

  @Test("deleteDomain sends DELETE")
  func deleteDomain() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/domains/allow/exact/example.com")
        #expect(request.httpMethod == "DELETE")
        let response = try #require(v6Response())
        return (Data("OK".utf8), response)
      }
    ]
    try await makeService().deleteDomain(domain: "example.com")
  }


  // MARK: - getRecentBlocked

  @Test("getRecentBlocked parses v6 response")
  func getRecentBlocked() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/queries")
        #expect(request.httpMethod == "GET")
        #expect(request.url?.query?.contains("status=") == true)
        #expect(request.url?.query?.contains("length=") == true)
        #expect(request.url?.query?.contains("from=") == true)
        #expect(request.url?.query?.contains("until=") == true)
        let response = try #require(v6Response())
        let data = Data(
          #"""
          {"queries":[
            {"domain":"doubleclick.net","time":1717200000.0,"client":{"ip":"192.168.1.5"}},
            {"domain":"ads.com","time":1717200060.0,"client":{"ip":"192.168.1.10"}}
          ]}
          """#.utf8)
        return (data, response)
      }
    ]
    let blocked = try await makeService().getRecentBlocked(
      forClientIp: nil,
      interval: DateInterval(start: Date().addingTimeInterval(-3600), end: Date())
    )
    #expect(blocked.count == 2)
    #expect(blocked[0].domain == "doubleclick.net")
    #expect(blocked[1].domain == "ads.com")
  }

  @Test("getRecentBlocked returns empty for no results")
  func getRecentBlockedEmpty() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/queries")
        #expect(request.httpMethod == "GET")
        let response = try #require(v6Response())
        return (Data(#"{"queries":[]}"#.utf8), response)
      }
    ]
    let blocked = try await makeService().getRecentBlocked(
      forClientIp: nil,
      interval: DateInterval(start: Date().addingTimeInterval(-3600), end: Date())
    )
    #expect(blocked.isEmpty)
  }

  @Test("getRecentBlocked throws on server error")
  func getRecentBlockedServerError() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/queries")
        #expect(request.httpMethod == "GET")
        let response = try #require(v6Response(statusCode: 500))
        return (Data("Error".utf8), response)
      }
    ]
    await #expect(throws: PiholeError.server(500, "Error")) {
      try await makeService().getRecentBlocked(
        forClientIp: nil,
        interval: DateInterval(start: Date(), end: Date())
      )
    }
  }

  // MARK: - getDomains

  @Test("getDomains decodes v6 wrapped response")
  func getDomains() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/domains")
        #expect(request.httpMethod == "GET")
        let response = try #require(v6Response())
        let data = Data(
          #"""
          {"domains":[
            {"id":1,"domain":"allowed.com","type":"allow","comment":""},
            {"id":2,"domain":"blocked.com","type":"deny","comment":"manual"}
          ]}
          """#.utf8)
        return (data, response)
      }
    ]
    let domains = try await makeService().getDomains()
    #expect(domains.count == 2)
    #expect(domains[0].domain == "allowed.com")
    #expect(domains[1].domain == "blocked.com")
  }

  @Test("getDomains returns empty list")
  func getDomainsEmpty() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/domains")
        #expect(request.httpMethod == "GET")
        let response = try #require(v6Response())
        return (Data(#"{"domains":[]}"#.utf8), response)
      }
    ]
    let domains = try await makeService().getDomains()
    #expect(domains.isEmpty)
  }

  @Test("getDomains throws on server error")
  func getDomainsServerError() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/domains")
        #expect(request.httpMethod == "GET")
        let response = try #require(v6Response(statusCode: 500))
        return (Data("Error".utf8), response)
      }
    ]
    await #expect(throws: PiholeError.server(500, "Error")) {
      try await makeService().getDomains()
    }
  }

  // MARK: - Auth lifecycle

  @Test("login succeeds")
  func loginSuccess() async throws {
    let mockAuth = MockAuthSessionProvider()
    let service = makeService(authSession: mockAuth)
    try await service.login()
    #expect(mockAuth.loginCallCount == 1)
  }

  @Test("login propagates auth session login errors")
  func loginError() async throws {
    let mockAuth = MockAuthSessionProvider()
    mockAuth.loginError = PiholeError.invalidCredentials
    let service = makeService(authSession: mockAuth)
    await #expect(throws: PiholeError.invalidCredentials) {
      try await service.login()
    }
    #expect(mockAuth.loginCallCount == 1)
  }

  @Test("logout calls auth session logout and invalidates session")
  func logout() async {
    let mockAuth = MockAuthSessionProvider()
    let service = makeService(authSession: mockAuth)
    await service.logout()
    #expect(mockAuth.logoutCallCount == 1)
    #expect(mockSession.invalidateAndCancelCallCount == 1)
  }
}
