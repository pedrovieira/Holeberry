import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("Pi-hole domain request safety")
struct PiholeDomainSafetyTests {
  @Test(
    "Malformed domains never reach the authenticated API",
    arguments: [ServerVersion.v5, .v6],
    [
      "evil.com/../../config", "evil.com\\..\\config", "%2e%2e%2fconfig", "..", ".", "", "user@example.com",
      "example.com:80", "example.com?x=1", "example.com#fragment", "example.com\n", "https://example.com"
    ]
  )
  func invalidDomain(version: ServerVersion, domain: String) async throws {
    let session = MockURLSession()
    let service = makeService(version, session: session)
    await #expect(throws: PiholeError.unknown("Invalid domain: \(domain)")) {
      try await service.deleteDomain(domain, from: .allow)
    }
    await #expect(throws: PiholeError.unknown("Invalid domain: \(domain)")) {
      try await service.getDomain(domain, from: .allow)
    }
    await #expect(throws: PiholeError.unknown("Invalid domain: \(domain)")) {
      try await service.addDomain(domain, to: .allow, comment: nil)
    }
    #expect(session.requests.isEmpty)
  }

  @Test("V6 lookups and deletes use one canonical path component", arguments: ["Example.COM", "BÜCHER.de"])
  func canonicalPath(domain: String) async throws {
    let session = MockURLSession()
    let service = makeService(.v6, session: session)
    let identity = domain == "Example.COM" ? "example.com" : "xn--bcher-kva.de"
    session.asyncHandler = { request in
      let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
      #expect(components.percentEncodedPath == "/api/domains/deny/exact/\(identity)")
      #expect(components.query == nil)
      #expect(components.fragment == nil)
      let body = request.httpMethod == "GET" ? #"{"domains":[]}"# : ""
      let status = request.httpMethod == "GET" ? 200 : 204
      return (
        Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      )
    }
    #expect(try await service.getDomain(domain, from: .deny) == nil)
    try await service.deleteDomain(domain, from: .deny)
    #expect(session.requests.count == 2)
  }

  @Test("V5 sends comments as encoded form data")
  func v5Comment() async throws {
    let session = MockURLSession()
    let service = makeService(.v5, session: session)
    let comment = "via holeberryapp.com / marker + &=test"
    session.handlers = [
      { request in
        (
          Data(#"{"data":[]}"#.utf8),
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      },
      { request in
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let form = String(data: request.httpBody!, encoding: .utf8)!
        #expect(form == "comment=via%20holeberryapp%2Ecom%20%2F%20marker%20%2B%20%26%3Dtest")
        return (
          Data(#"{"success":true,"message":"Added example.com"}"#.utf8),
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      }
    ]
    #expect(try await service.addDomain("example.com", to: .allow, comment: comment) == .added)
  }

  private func makeService(_ version: ServerVersion, session: MockURLSession) -> any PiholeServiceCommentAdding {
    let url = URL(string: "http://test.local")!
    if version == .v5 {
      return PiholeV5Service(
        id: UUID(), label: nil, url: url.absoluteString, version: .v5,
        baseURL: url, session: session, apiToken: "test-token"
      )
    }
    return PiholeV6Service(
      id: UUID(), label: nil, url: url.absoluteString, version: .v6,
      baseURL: url, urlSession: session, authSession: MockAuthSessionProvider()
    )
  }
}
