import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@Suite("PiholeServiceFactory")
@MainActor
struct PiholeServiceFactoryTests {
  @Test("Both versions manage temporary allowances and cleanup through the factory", arguments: [ServerVersion.v5, .v6])
  func managedUnblock(version: ServerVersion) async throws {
    let session = MockURLSession()
    let mockAuthFactory = MockAuthSessionFactory()
    mockAuthFactory.stubbedProvider = MockAuthSessionProvider()
    let factory = ConcretePiholeServiceFactory(authSessionFactory: mockAuthFactory)
    let suite = TestDefaults.makeSuite()
    let config = ServerConfig(label: "Test", url: "http://test.local", version: version)
    let key = Defaults.Keys.tempUnblocks(for: config.id, suite: suite)
    defer { Defaults[key] = [] }
    var comment: String?
    session.asyncHandler = { request in
      let body: String
      let status: Int
      if version == .v5 {
        #expect(request.url?.path == "/admin/api.php")
        let items = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains { $0.name == "auth" && $0.value == "api-token" })
        #expect(items.contains { $0.name == "list" && $0.value == "white" })
        if items.contains(where: { $0.name == "add" && $0.value == "example.com" }) {
          #expect(request.httpMethod == "POST")
          let form = try #require(String(data: request.httpBody!, encoding: .utf8))
          comment = String(form.dropFirst("comment=".count)).removingPercentEncoding
          body = #"{"success":true,"message":"Added example.com"}"#
        } else if items.contains(where: { $0.name == "sub" && $0.value == "example.com" }) {
          body = #"{"success":true,"message":null}"#
        } else {
          #expect(request.httpMethod == "GET")
          body = #"{"data":[]}"#
        }
        status = 200
      } else if request.httpMethod == "POST" {
        #expect(request.url?.path == "/api/domains/allow/exact")
        let data = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["domain"] as? String == "example.com")
        comment = json["comment"] as? String
        body = #"{"processed":{"success":[{"item":"example.com"}],"errors":[]}}"#
        status = 201
      } else {
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/domains/allow/exact/example.com")
        body = ""
        status = 204
      }
      return (
        Data(body.utf8),
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      )
    }
    let service: any PiholeServiceProviding = try factory.buildService(
      config: config, credential: "api-token", session: session, suite: suite
    )
    #expect(service.id == config.id)
    #expect(service.label == "Test")
    #expect(service.url == config.url)
    #expect(service.version == version)

    do {
      #expect(try await service.unblockDomain("Example.COM", duration: 3600) == .added)
      let record = try #require(Defaults[key].first)
      #expect(Defaults[key].count == 1)
      #expect(record.domain == "example.com")
      #expect(record.durationSeconds == 3600)
      #expect(record.uuid == comment)
      #expect(record.uuid.hasPrefix("via holeberryapp.com / "))
      #expect(session.requests.count == (version == .v5 ? 2 : 1))
    } catch {
      try? await service.deleteDomain("example.com", from: .allow)
      throw error
    }

    // Deleting through the returned managed interface cancels its expiry task
    // and removes the persisted cleanup record.
    try await service.deleteDomain("example.com", from: .allow)
    #expect(Defaults[key].isEmpty)
    await settle()
    #expect(session.requests.count == (version == .v5 ? 3 : 2))
  }
}
