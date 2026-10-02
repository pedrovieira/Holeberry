import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("Domain unblock recovery")
struct DomainUnblockRecoveryTests {
  @Test(
    "Short unblocks retain their full duration after slow adds and recovery",
    arguments: [ServerVersion.v5, .v6], [false, true]
  )
  func durationStartsAfterConfirmation(version: ServerVersion, recover: Bool) async throws {
    let session = MockURLSession()
    let service = makeService(version, session: session)
    let suite = TestDefaults.makeSuite()
    let duration: TimeInterval = 0.01
    var marker: String?
    var confirmedAt: Date?
    var expiryDelay: TimeInterval?
    var expire: CheckedContinuation<Void, Never>?
    var deletes = 0
    session.asyncHandler = { request in
      let isV5 = version == .v5
      let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      if request.httpMethod == "DELETE" || items.contains(where: { $0.name == "sub" }) {
        deletes += 1
        return reply(isV5 ? #"{"success":true}"# : "", request: request, status: isV5 ? 200 : 204)
      }
      if request.httpMethod == "POST" {
        if isV5 {
          let form = String(data: request.httpBody!, encoding: .utf8)!
          marker = String(form.dropFirst("comment=".count)).removingPercentEncoding
        } else {
          let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
          marker = body["comment"]
        }
        // The add takes longer than the selected unblock duration.
        try await Task.sleep(for: .milliseconds(30))
        if recover { throw URLError(.timedOut) }
        confirmedAt = Date()
        let body =
          isV5
          ? #"{"success":true,"message":"Added example.com"}"#
          : #"{"processed":{"success":[{"item":"example.com"}],"errors":[]}}"#
        return reply(body, request: request, status: isV5 ? 200 : 201)
      }
      if marker != nil {
        // A recovery lookup also must not consume the unblock duration.
        try await Task.sleep(for: .milliseconds(30))
        confirmedAt = Date()
      }
      return reply(listBody(version, marker: marker), request: request)
    }
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: service, defaultsSuite: suite) { remaining in
      expiryDelay = remaining
      await withCheckedContinuation { expire = $0 }
    }
    #expect(try await decorator.unblockDomain("example.com", duration: duration) == .added)
    let record = try #require(Defaults[.tempUnblocks(for: service.id, suite: suite)].first)
    let confirmation = try #require(confirmedAt)
    #expect(record.startDateUTC >= confirmation)
    #expect(record.startDateUTC.addingTimeInterval(record.durationSeconds) >= confirmation.addingTimeInterval(duration))
    #expect(record.durationSeconds == duration)
    await waitUntil { expire != nil }
    #expect(expiryDelay != nil)
    #expect(deletes == 0)
    expire?.resume()
    await waitUntil { deletes == 1 && Defaults[.tempUnblocks(for: service.id, suite: suite)].isEmpty }
  }

  @Test("Lost add responses are recovered with one ownership lookup", arguments: [ServerVersion.v5, .v6])
  func lostResponse(version: ServerVersion) async throws {
    let session = MockURLSession()
    let service = makeService(version, session: session)
    let suite = TestDefaults.makeSuite()
    var marker: String?
    var adds = 0
    var deletes = 0
    var recoveryReads = 0
    var expire = false
    session.asyncHandler = { request in
      let isV5 = version == .v5
      let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      if request.httpMethod == "DELETE" || items.contains(where: { $0.name == "sub" }) {
        deletes += 1
        marker = nil
        return reply(isV5 ? #"{"success":true}"# : "", request: request, status: isV5 ? 200 : 204)
      }
      if request.httpMethod == "POST" {
        adds += 1
        #expect(Defaults[.tempUnblocks(for: service.id, suite: suite)].isEmpty)
        if isV5 {
          #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
          let form = String(data: request.httpBody!, encoding: .utf8)!
          marker = String(form.dropFirst("comment=".count)).removingPercentEncoding
        } else {
          let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
          marker = body["comment"]
        }
        throw URLError(.timedOut)
      }
      if marker != nil { recoveryReads += 1 }
      return reply(listBody(version, marker: marker), request: request)
    }
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: service, defaultsSuite: suite) { _ in
      while !expire { try await Task.sleep(for: .milliseconds(1)) }
    }
    let outcome = try await withRetry(
      .destructive, sleep: { _ in },
      operation: { try await decorator.unblockDomain("Example.COM", duration: 300) }
    )
    #expect(outcome == .added)
    #expect(adds == 1, "Recover the committed insert without sending another mutation")
    let record = try #require(Defaults[.tempUnblocks(for: service.id, suite: suite)].first)
    #expect(record.domain == "example.com")
    #expect(recoveryReads == 1)
    #expect(record.uuid == marker)
    expire = true
    await waitUntil { deletes == 1 && Defaults[.tempUnblocks(for: service.id, suite: suite)].isEmpty }
    #expect(Defaults[.tempUnblocks(for: service.id, suite: suite)].isEmpty)
  }

  @Test("An unsuccessful recovery preserves the original error", arguments: ["absent", "manual", "offline"])
  func failedRecovery(result: String) async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .failure(PiholeError.network("response lost"))
    switch result {
    case "manual":
      mock.getDomainStub = .success(DomainEntry(id: 1, domain: "example.com", type: 0, comment: "manual"))
    case "offline":
      mock.getDomainStub = .failure(PiholeError.network("lookup failed"))
    default:
      mock.getDomainStub = .success(nil)
    }
    let suite = TestDefaults.makeSuite()
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: mock, defaultsSuite: suite) { _ in
      Issue.record("An unsuccessful recovery must not create an expiry timer")
    }
    await #expect(throws: PiholeError.network("response lost")) {
      try await decorator.unblockDomain("example.com", duration: 300)
    }
    #expect(mock.getDomainCallCount == 1)
    #expect(mock.deleteDomainCallCount == 0)
    #expect(Defaults[.tempUnblocks(for: mock.id, suite: suite)].isEmpty)
  }

  @Test("A confirmed add does not need a recovery lookup")
  func confirmedAdd() async throws {
    let mock = MockPiholeService()
    let suite = TestDefaults.makeSuite()
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: mock, defaultsSuite: suite) { _ in
      try await Task.sleep(for: .seconds(60))
    }
    #expect(try await decorator.unblockDomain("example.com", duration: 300) == .added)
    #expect(mock.getDomainCallCount == 0)
    #expect(Defaults[.tempUnblocks(for: mock.id, suite: suite)].count == 1)
  }

  @Test(
    "Restart keeps mixed-case and Unicode records", arguments: [ServerVersion.v5, .v6], ["Example.COM", "bücher.de"])
  func restartIdentity(version: ServerVersion, domain: String) async throws {
    let session = MockURLSession()
    let service = makeService(version, session: session)
    let suite = TestDefaults.makeSuite()
    let identity = domain == "Example.COM" ? "example.com" : "xn--bcher-kva.de"
    let wireDomain = version == .v5 && domain == "bücher.de" ? "b&uuml;cher.de (xn--bcher-kva.de)" : identity
    var deleted = false
    var delay: TimeInterval?
    session.asyncHandler = { request in
      let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      if request.httpMethod == "DELETE" || items.contains(where: { $0.name == "sub" }) {
        if version == .v5 {
          #expect(items.first(where: { $0.name == "sub" })?.value == identity)
        } else {
          #expect(request.url?.path == "/api/domains/allow/exact/\(identity)")
        }
        deleted = true
        return reply(version == .v5 ? #"{"success":true}"# : "", request: request, status: version == .v5 ? 200 : 204)
      }
      return reply(listBody(version, marker: "record", domain: wireDomain), request: request)
    }
    Defaults[.tempUnblocks(for: service.id, suite: suite)] = [
      TempUnblockRecord(
        domain: domain, uuid: "record", startDateUTC: Date().addingTimeInterval(-100), durationSeconds: 300)
    ]
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: service, defaultsSuite: suite) { remaining in
      delay = remaining
    }
    await waitUntil { deleted && Defaults[.tempUnblocks(for: service.id, suite: suite)].isEmpty }
    #expect(try #require(delay) > 190)
    #expect(try #require(delay) < 210, "Restart must not restart the full duration")
    #expect(Defaults[.tempUnblocks(for: service.id, suite: suite)].isEmpty)
    withExtendedLifetime(decorator) {}
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

  private func reply(_ body: String, request: URLRequest, status: Int = 200) -> (Data, HTTPURLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }

  private func listBody(_ version: ServerVersion, marker: String?, domain: String = "example.com") -> String {
    guard let marker else { return version == .v5 ? #"{"data":[]}"# : #"{"domains":[]}"# }
    let row = "{\"id\":1,\"domain\":\"\(domain)\",\"type\":0,\"enabled\":true,\"comment\":\"\(marker)\"}"
    return "{\"\(version == .v5 ? "data" : "domains")\":[\(row)]}"
  }
}
