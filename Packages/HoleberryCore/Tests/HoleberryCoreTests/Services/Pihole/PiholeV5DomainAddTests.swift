import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("V5 domain add ownership")
struct PiholeV5DomainAddTests {
  private let session = MockURLSession()

  private func makeService() -> PiholeV5Service {
    PiholeV5Service(
      id: UUID(), label: nil, url: "http://test.local", version: .v5,
      baseURL: URL(string: "http://test.local")!, session: session, apiToken: "test-token"
    )
  }

  private func reply(_ body: String) -> (Data, HTTPURLResponse) {
    (
      Data(body.utf8),
      HTTPURLResponse(
        url: URL(string: "http://test.local")!, statusCode: 200,
        httpVersion: nil, headerFields: nil)!
    )
  }

  @Test("Only a matching insertion message confirms ownership", arguments: ["Example.COM", "bücher.de"])
  func confirmedAdd(domain: String) async throws {
    let identity = try #require(URL(string: "http://\(domain)")?.host?.lowercased())
    session.handlers = [
      { _ in reply(#"{"data":[]}"#) },
      { _ in reply("{\"success\":true,\"message\":\"Added \(identity)\"}") }
    ]
    #expect(try await makeService().addDomain(domain, to: .allow, comment: nil) == .added)
  }

  @Test("An external insertion between read and add is not tracked", arguments: [DomainListType.allow, .deny])
  func duplicateAfterRead(list: DomainListType) async throws {
    session.handlers = [
      { _ in reply(#"{"data":[]}"#) },
      { _ in reply(#"{"success":true,"message":"Not adding example.com as it is already on the list"}"#) }
    ]
    #expect(try await makeService().addDomain("example.com", to: list, comment: "tracking-id") == .alreadyPresent)
  }

  @Test(
    "Unconfirmed additions are not tracked when recovery fails",
    arguments: [
      #"{"success":true}"#, #"{"success":true,"message":null}"#,
      #"{"success":true,"message":"Added other.com"}"#,
      #"{"success":true,"message":"Added 1 out of 1 domains"}"#,
      #"{"success":true,"message":"Not adding other.com as it is already on the list"}"#
    ]
  )
  func unconfirmedAdd(body: String) async throws {
    session.handlers = [{ _ in reply(#"{"data":[]}"#) }, { _ in reply(body) }]
    let service = makeService()
    let suite = TestDefaults.makeSuite()
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: service, defaultsSuite: suite) { _ in
      Issue.record("An unconfirmed add must not start an expiry timer")
    }
    await #expect {
      try await decorator.unblockDomain("example.com", duration: 60, ownershipID: UUID())
    } throws: { error in
      guard case PiholeError.decoding = error else { return false }
      return true
    }
    #expect(Defaults[.tempUnblocks(for: service.id, suite: suite)].isEmpty)
    #expect(session.requests.count == 3, "The add error triggers one recovery lookup")
  }

  @Test("Overlapping adds of the same domain run serially", arguments: ["Example.COM", "bücher.de"])
  func overlappingAdds(domain: String) async throws {
    let identity = try #require(URL(string: "http://\(domain)")?.host?.lowercased())
    var releaseFirst = false
    var inserted = false
    session.asyncHandler = { request in
      if request.url?.query?.contains("add=") == true {
        inserted = true
        return reply("{\"success\":true,\"message\":\"Added \(identity)\"}")
      }
      if inserted {
        return reply("{\"data\":[{\"id\":1,\"domain\":\"\(identity)\",\"type\":0,\"comment\":null}]}")
      }
      await waitUntil { releaseFirst }
      return reply(#"{"data":[]}"#)
    }
    let service = makeService()
    let first = Task { try await service.addDomain(domain, to: .allow, comment: nil) }
    await waitUntil { session.requests.count == 1 }
    let second = Task { try await service.addDomain(identity, to: .allow, comment: nil) }
    await settle()
    #expect(session.requests.count == 1, "The second caller must wait before reading")
    releaseFirst = true
    #expect(try await first.value == .added)
    #expect(try await second.value == .alreadyPresent)
    #expect(session.requests.count == 3, "Only the first caller writes")
  }

  @Test("An add failure releases the next caller")
  func failureReleasesQueue() async throws {
    var releaseFirst = false
    var reads = 0
    var writes = 0
    session.asyncHandler = { request in
      if request.url?.query?.contains("add=") == true {
        writes += 1
        return writes == 1
          ? reply(#"{"success":false,"message":"database is locked"}"#)
          : reply(#"{"success":true,"message":"Added example.com"}"#)
      }
      reads += 1
      if reads == 1 { await waitUntil { releaseFirst } }
      return reply(#"{"data":[]}"#)
    }
    let service = makeService()
    let first = Task { try await service.addDomain("example.com", to: .allow, comment: nil) }
    await waitUntil { session.requests.count == 1 }
    let second = Task { try await service.addDomain("example.com", to: .allow, comment: nil) }
    await settle()
    releaseFirst = true
    await #expect(throws: PiholeError.server(200, "database is locked")) { try await first.value }
    #expect(try await second.value == .added)
    #expect(session.requests.count == 4)
  }

  @Test("A canceled queued caller performs no requests and releases the next caller")
  func canceledCallerReleasesQueue() async throws {
    var releaseFirst = false
    var inserted = false
    session.asyncHandler = { request in
      if request.url?.query?.contains("add=") == true {
        inserted = true
        return reply(#"{"success":true,"message":"Added example.com"}"#)
      }
      if inserted {
        return reply(#"{"data":[{"id":1,"domain":"example.com","type":0,"comment":null}]}"#)
      }
      await waitUntil { releaseFirst }
      return reply(#"{"data":[]}"#)
    }
    let service = makeService()
    let first = Task { try await service.addDomain("example.com", to: .allow, comment: nil) }
    await waitUntil { session.requests.count == 1 }
    let canceled = Task { try await service.addDomain("example.com", to: .allow, comment: nil) }
    await settle()
    canceled.cancel()
    let third = Task { try await service.addDomain("example.com", to: .allow, comment: nil) }
    await settle()
    releaseFirst = true
    #expect(try await first.value == .added)
    await #expect(throws: CancellationError.self) { try await canceled.value }
    #expect(try await third.value == .alreadyPresent)
    #expect(session.requests.count == 3)
  }

  @Test("Different domains also wait to keep v5's total row count stable")
  func differentDomainsWait() async throws {
    var releaseFirst = false
    var reads = 0
    session.asyncHandler = { request in
      let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      if let domain = items.first(where: { $0.name == "add" })?.value {
        return reply("{\"success\":true,\"message\":\"Added \(domain)\"}")
      }
      reads += 1
      if reads == 1 { await waitUntil { releaseFirst } }
      return reply(#"{"data":[]}"#)
    }
    let service = makeService()
    let first = Task { try await service.addDomain("example.com", to: .allow, comment: nil) }
    await waitUntil { session.requests.count == 1 }
    let other = Task { try await service.addDomain("other.com", to: .allow, comment: nil) }
    await settle()
    #expect(session.requests.count == 1)
    releaseFirst = true
    #expect(try await first.value == .added)
    #expect(try await other.value == .added)
    #expect(session.requests.count == 4)
  }

  @Test("Expiry deletions wait for an in-flight add to keep the total row count stable")
  func deletionsWaitForAdds() async throws {
    var releaseRead = false
    session.asyncHandler = { request in
      let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      if items.contains(where: { $0.name == "add" }) {
        return reply(#"{"success":true,"message":"Added example.com"}"#)
      }
      if items.contains(where: { $0.name == "sub" }) {
        return reply(#"{"success":true,"message":null}"#)
      }
      await waitUntil { releaseRead }
      return reply(#"{"data":[]}"#)
    }
    let service = makeService()
    let add = Task { try await service.addDomain("example.com", to: .allow, comment: nil) }
    await waitUntil { session.requests.count == 1 }
    let delete = Task { try await service.deleteDomain("expired.com", from: .allow) }
    await settle()
    #expect(session.requests.count == 1)
    releaseRead = true
    #expect(try await add.value == .added)
    try await delete.value
    #expect(session.requests.count == 3)
    #expect(session.requests[1].url?.query?.contains("add=") == true)
    #expect(session.requests[2].url?.query?.contains("sub=") == true)
  }
}
