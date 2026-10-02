import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("Domain unblock outcomes")
struct DomainUnblockOutcomeTests {
  @Test(
    "Existing entries report their enabled state and never start a timer",
    arguments: [ServerVersion.v5, .v6], [Bool?.some(true), .some(false), nil]
  )
  func existingEntry(version: ServerVersion, enabled: Bool?) async throws {
    let service = MockPiholeService(version: version)
    service.addDomainStub = .success(.alreadyPresent)
    service.getDomainStub = .success(
      DomainEntry(id: 1, domain: "example.com", type: 0, comment: "manual", enabled: enabled)
    )
    let suite = TestDefaults.makeSuite()
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: service, defaultsSuite: suite) { _ in
      Issue.record("An existing entry must not start an expiry timer")
    }
    #expect(try await decorator.unblockDomain("Example.COM", duration: 60) == .alreadyPresent(enabled: enabled))
    #expect(Defaults[.tempUnblocks(for: service.id, suite: suite)].isEmpty)
    #expect(service.deleteDomainByNameCallCount == 0)
    #expect(service.getDomainCallCount == 1)
    #expect(service.getDomainLastDomain == "Example.COM")
    #expect(service.getDomainLastList == .allow)
  }

  @Test("Unreadable existing entries report a no-op with unknown state")
  func unknownExistingState() async throws {
    let service = MockPiholeService()
    service.addDomainStub = .success(.alreadyPresent)
    service.getDomainStub = .failure(PiholeError.network("offline"))
    let suite = TestDefaults.makeSuite()
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: service, defaultsSuite: suite) { _ in
      Issue.record("A duplicate must not start an expiry timer")
    }
    #expect(try await decorator.unblockDomain("example.com", duration: 60) == .alreadyPresent(enabled: nil))
    #expect(Defaults[.tempUnblocks(for: service.id, suite: suite)].isEmpty)
  }

  @Test("Permanent additions also expose no-ops")
  func permanentExistingEntry() async throws {
    let service = MockPiholeService()
    service.addDomainStub = .success(.alreadyPresent)
    service.getDomainStub = .success(
      DomainEntry(id: 1, domain: "example.com", type: 0, comment: "manual", enabled: false)
    )
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: service, defaultsSuite: TestDefaults.makeSuite())
    #expect(try await decorator.unblockDomain("example.com", duration: nil) == .alreadyPresent(enabled: false))
  }

  @Test("Unicode domains resolve existing ASCII entries", arguments: [ServerVersion.v5, .v6])
  func internationalExistingEntry(version: ServerVersion) async throws {
    let session = MockURLSession()
    let baseURL = URL(string: "http://test.local")!
    let service: any PiholeServiceCommentAdding
    if version == .v5 {
      service = PiholeV5Service(
        id: UUID(), label: nil, url: baseURL.absoluteString, version: .v5,
        baseURL: baseURL, session: session, apiToken: "test-token"
      )
    } else {
      service = PiholeV6Service(
        id: UUID(), label: nil, url: baseURL.absoluteString, version: .v6,
        baseURL: baseURL, urlSession: session, authSession: MockAuthSessionProvider()
      )
    }
    session.asyncHandler = { request in
      let body: String
      if version == .v5 {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(!items.contains { $0.name == "add" || $0.name == "sub" })
        body =
          #"{"data":[{"domain":"b&uuml;cher.de (xn--bcher-kva.de)","type":0,"enabled":0}]}"#
      } else if request.httpMethod == "POST" {
        return (
          Data(), HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
        )
      } else {
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/domains/allow/exact/xn--bcher-kva.de")
        body = #"{"domains":[{"domain":"xn--bcher-kva.de","type":"allow","enabled":false}]}"#
      }
      return (
        Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    #expect(try await service.unblockDomain("BÜCHER.de", duration: nil) == .alreadyPresent(enabled: false))
    #expect(session.requests.count == 2)
  }

  @Test("V5 pre-existing entries are only read, preserving disabled state and group assignments")
  func v5ExistingConfigurationPreserved() async throws {
    let session = MockURLSession()
    let service = PiholeV5Service(
      id: UUID(), label: nil, url: "http://test.local", version: .v5,
      baseURL: URL(string: "http://test.local")!, session: session, apiToken: "test-token"
    )
    let body = #"{"data":[{"id":1,"type":0,"domain":"example.com","enabled":0,"comment":"manual","groups":[2]}]}"#
    session.asyncHandler = { request in
      let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      #expect(!items.contains { $0.name == "add" || $0.name == "sub" })
      #expect(items.contains { $0.name == "list" && $0.value == "white" })
      return (
        Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let suite = TestDefaults.makeSuite()
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: service, defaultsSuite: suite)
    #expect(try await decorator.unblockDomain("example.com", duration: 60) == .alreadyPresent(enabled: false))
    #expect(session.requests.count == 2)
    #expect(Defaults[.tempUnblocks(for: service.id, suite: suite)].isEmpty)
  }

  @Test("A V5 external duplicate reports a no-op and is never tracked for deletion")
  func v5ExternalDuplicateIsNotTracked() async throws {
    let session = MockURLSession()
    let service = PiholeV5Service(
      id: UUID(), label: nil, url: "http://test.local", version: .v5,
      baseURL: URL(string: "http://test.local")!, session: session, apiToken: "test-token"
    )
    let bodies = [
      #"{"data":[]}"#,
      #"{"success":true,"message":"Not adding example.com as it is already on the list"}"#,
      #"{"data":[{"id":1,"type":0,"domain":"example.com","enabled":1,"comment":"","groups":[0]}]}"#
    ]
    session.handlers = bodies.map { body in
      { request in
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
      }
    }
    let suite = TestDefaults.makeSuite()
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: service, defaultsSuite: suite) { _ in
      Issue.record("A duplicate must not start an expiry timer")
    }
    #expect(try await decorator.unblockDomain("example.com", duration: 60) == .alreadyPresent(enabled: true))
    #expect(Defaults[.tempUnblocks(for: service.id, suite: suite)].isEmpty)
    #expect(session.requests.count == 3)
  }

  @Test(
    "V6 duplicates use a single-domain lookup without modifying the existing entry",
    arguments: [201, 400, 409], [TimeInterval?.some(60), nil]
  )
  func v6ExistingConfigurationPreserved(status: Int, duration: TimeInterval?) async throws {
    let session = MockURLSession()
    let service = PiholeV6Service(
      id: UUID(), label: nil, url: "http://test.local", version: .v6,
      baseURL: URL(string: "http://test.local")!, urlSession: session, authSession: MockAuthSessionProvider()
    )
    let duplicate: String
    if status == 201 {
      duplicate =
        #"{"processed":{"success":[],"errors":[{"item":"example.com","error":"UNIQUE constraint failed: domainlist.domain, domainlist.type"}]}}"#
    } else {
      duplicate =
        #"{"error":{"key":"database_error","hint":"UNIQUE constraint failed: domainlist.domain, domainlist.type"}}"#
    }
    session.handlers = [
      { request in
        #expect(request.httpMethod == "POST")
        return (
          Data(duplicate.utf8),
          HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: nil)!
        )
      },
      { request in
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/domains/allow/exact/example.com")
        let body =
          #"{"domains":[{"id":1,"domain":"example.com","type":"allow","kind":"exact","enabled":false,"comment":"manual","groups":[2]}]}"#
        return (
          Data(body.utf8),
          HTTPURLResponse(
            url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!
        )
      }
    ]
    let suite = TestDefaults.makeSuite()
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: service, defaultsSuite: suite)
    #expect(try await decorator.unblockDomain("Example.COM", duration: duration) == .alreadyPresent(enabled: false))
    #expect(session.requests.count == 2)
    #expect(Defaults[.tempUnblocks(for: service.id, suite: suite)].isEmpty)
  }

  @Test(
    "V6 missing or unreadable entries preserve the duplicate outcome with unknown state",
    arguments: [(200, #"{"domains":[]}"#), (500, "offline"), (200, "invalid JSON")]
  )
  func v6UnknownExistingState(status: Int, body: String) async throws {
    let session = MockURLSession()
    let service = PiholeV6Service(
      id: UUID(), label: nil, url: "http://test.local", version: .v6,
      baseURL: URL(string: "http://test.local")!, urlSession: session, authSession: MockAuthSessionProvider()
    )
    session.handlers = [
      { request in
        #expect(request.httpMethod == "POST")
        return (
          Data(), HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
        )
      },
      { request in
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/domains/allow/exact/example.com")
        return (
          Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
      }
    ]
    #expect(try await service.unblockDomain("Example.COM", duration: nil) == .alreadyPresent(enabled: nil))
    #expect(session.requests.count == 2)
  }
}
