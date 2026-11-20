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
      config: config, credential: "api-token", session: session,
      storage: makeTestStorage(appLocalSuite: suite), executionMode: .application
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

  @Test(
    "Factory wraps both versions and restores records from the injected storage",
    arguments: [ServerVersion.v5, .v6]
  )
  func restoresRecordsFromInjectedStorage(version: ServerVersion) throws {
    let session = MockURLSession()
    let mockAuthFactory = MockAuthSessionFactory()
    mockAuthFactory.stubbedProvider = MockAuthSessionProvider()
    let factory = ConcretePiholeServiceFactory(authSessionFactory: mockAuthFactory)
    let (sharedDataSuiteName, sharedDataSuite) = TestDefaults.makeNamedSuite()
    let appLocalSuite = TestDefaults.makeSuite()
    let config = ServerConfig(label: "Test", url: "http://restore.local", version: version)
    // Configurations use a different suite from temporary records.
    Defaults[.servers(suite: sharedDataSuite)] = [config]
    Defaults[.servers(suite: appLocalSuite)] = [
      ServerConfig(label: "Wrong Suite", url: "http://wrong.local", version: .v6)
    ]
    // Started a minute ago with an hour duration, so the record is live: the
    // decorator schedules a far-future expiry instead of expiring during the test.
    let startDate = Date().addingTimeInterval(-60)
    let record = TempUnblockRecord(
      domain: "Restored.Example",
      uuid: "restored-token",
      startDateUTC: startDate,
      durationSeconds: 3_600,
      pendingRemoval: false,
      retryCount: 1
    )
    Defaults[.tempUnblocks(for: config.id, suite: appLocalSuite)] = [record]
    let storage = makeTestStorage(
      appLocalSuite: appLocalSuite, sharedData: (sharedDataSuiteName, sharedDataSuite))

    let service = try factory.buildService(
      config: config, credential: "api-token", session: session, storage: storage,
      executionMode: .application)

    #expect(
      service is TemporaryUnblockPiholeServiceDecorator,
      "every raw service must stay wrapped by the temporary-unblock decorator")
    #expect(service.id == config.id)
    #expect(service.version == version)

    // Init restored the record through the injected storage, normalizing the
    // domain and preserving every other field.
    let restored: [TempUnblockRecord] = Defaults[.tempUnblocks(for: config.id, suite: appLocalSuite)]
    #expect(restored.count == 1)
    let saved = try #require(restored.first)
    #expect(saved.domain == "restored.example")
    #expect(saved.uuid == "restored-token")
    #expect(saved.startDateUTC == startDate)
    #expect(saved.durationSeconds == 3_600)
    #expect(saved.pendingRemoval == false)
    #expect(saved.retryCount == 1)

    // The adapter's shared-data suite is the injected one, not the app-local suite.
    let configs = storage.loadServers()
    #expect(configs.count == 1)
    #expect(configs.first?.id == config.id)
  }

  @Test("Production factory on-demand clients authenticate only on requests", arguments: [ServerVersion.v5, .v6])
  func lazyAuthentication(version: ServerVersion) async throws {
    let suite = TestDefaults.makeSuite()
    let session = MockURLSession()
    let config = ServerConfig(url: "http://test.local", version: version)
    let storage = makeTestStorage(appLocalSuite: suite)
    let record = TempUnblockRecord(
      domain: "EXAMPLE.COM", uuid: "existing", startDateUTC: .distantPast, durationSeconds: 1
    )
    storage.saveTemporaryUnblocks([record], for: config.id)
    session.asyncHandler = { request in
      let body: String
      if request.url?.path == "/api/auth" {
        #expect(request.httpMethod == "POST")
        body = #"{"session":{"valid":true,"sid":"test-sid","csrf":"test-csrf","validity":300,"totp":false}}"#
      } else if version == .v5 {
        #expect(request.url?.path == "/admin/api.php")
        #expect(request.url?.query?.contains("auth=secret") == true)
        body = #"{"status":"enabled"}"#
      } else {
        #expect(request.url?.path == "/api/dns/blocking")
        #expect(request.value(forHTTPHeaderField: "X-FTL-SID") == "test-sid")
        body = #"{"blocking":"enabled","timer":null}"#
      }
      return (
        Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let factory = ConcretePiholeServiceFactory(authSessionFactory: ConcreteAuthSessionFactory())
    let service = try factory.buildService(
      config: config, credential: "secret", session: session, storage: storage,
      executionMode: .onDemand
    )
    await settle()
    #expect(session.requests.isEmpty)
    #expect(storage.loadTemporaryUnblocks(for: config.id) == [record])
    #expect(try await service.checkStatus() == .enabled)
    #expect(session.requests.count == (version == .v5 ? 1 : 2))
    #expect(storage.loadTemporaryUnblocks(for: config.id) == [record])
  }

}
