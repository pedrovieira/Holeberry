import Foundation

@testable import PiHoleMenuApp

/// Configurable mock implementing `PiholeServiceProtocol` with stub injection, call-count tracking, and failure injection.
final class MockPiholeService: PiholeServiceProtocol {
  let id: UUID
  var label: String?
  var url: String
  var version: ServerVersion

  var checkStatusStub: Result<BlockingStatus, Error> = .success(.enabled)
  var checkStatusCallCount = 0

  var setBlockingStub: Result<Void, Error> = .success(())
  var setBlockingCallCount = 0
  var setBlockingLastEnabled: Bool?
  var setBlockingLastDuration: TimeInterval?

  var getRecentBlockedStub: Result<[String], Error> = .success([])
  var getRecentBlockedCallCount = 0

  var getRecentQueriesStub: Result<[RecentQuery], Error> = .success([])
  var getRecentQueriesCallCount = 0

  var getQuerySummaryStub: Result<QuerySummary, Error> = .success(QuerySummary(totalQueries: 0, totalBlocked: 0))
  var getQuerySummaryCallCount = 0

  var addDomainStub: Result<DomainEntry, Error> = .success(
    DomainEntry(id: 1, domain: "test.com", type: 0, comment: nil))
  var addDomainCallCount = 0
  var addDomainLastDomain: String?
  var addDomainLastList: DomainListType?
  var addDomainLastComment: String?

  var deleteDomainByIDStub: Result<Void, Error> = .success(())
  var deleteDomainByIDCallCount = 0

  var deleteDomainByNameStub: Result<Void, Error> = .success(())
  var deleteDomainByNameCallCount = 0

  var getDomainsStub: Result<[DomainEntry], Error> = .success([])
  var getDomainsCallCount = 0

  var refreshSessionCallCount = 0
  var refreshSessionLastURL: String?

  var logoutCallCount = 0

  init(id: UUID = UUID(), label: String? = nil, url: String = "http://test.local", version: ServerVersion = .v6) {
    self.id = id
    self.label = label
    self.url = url
    self.version = version
  }

  func checkStatus() async throws -> BlockingStatus {
    checkStatusCallCount += 1
    return try checkStatusStub.get()
  }

  func setBlocking(enabled: Bool, duration: TimeInterval?) async throws {
    setBlockingCallCount += 1
    setBlockingLastEnabled = enabled
    setBlockingLastDuration = duration
    try setBlockingStub.get()
  }

  func getRecentBlocked(count: Int) async throws -> [String] {
    getRecentBlockedCallCount += 1
    return try getRecentBlockedStub.get()
  }

  func getRecentQueries(clientIP: String?) async throws -> [RecentQuery] {
    getRecentQueriesCallCount += 1
    return try getRecentQueriesStub.get()
  }

  func getQuerySummary() async throws -> QuerySummary {
    getQuerySummaryCallCount += 1
    return try getQuerySummaryStub.get()
  }

  func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainEntry {
    addDomainCallCount += 1
    addDomainLastDomain = domain
    addDomainLastList = list
    addDomainLastComment = comment
    return try addDomainStub.get()
  }

  func deleteDomain(identifiedBy id: Int) async throws {
    deleteDomainByIDCallCount += 1
    try deleteDomainByIDStub.get()
  }

  func deleteDomain(domain: String) async throws {
    deleteDomainByNameCallCount += 1
    try deleteDomainByNameStub.get()
  }

  func getDomains() async throws -> [DomainEntry] {
    getDomainsCallCount += 1
    return try getDomainsStub.get()
  }

  func refreshSession(from urlString: String) {
    refreshSessionCallCount += 1
    refreshSessionLastURL = urlString
    self.url = urlString
  }

  func logout() async {
    logoutCallCount += 1
  }
}

final class MockServerProvider: ServerProviding {
  var servers: [ServerConfig] = []
  var makeService: ((ServerConfig) -> PiholeServiceProtocol)?

  private(set) var performCallCount = 0
  private(set) var lastServerID: UUID?

  func perform<T>(for id: UUID, block: (PiholeServiceProtocol) async throws -> T) async throws -> T {
    performCallCount += 1
    lastServerID = id
    guard let config = servers.first(where: { $0.id == id }) else {
      throw PiholeError.unknown("Server not found in mock")
    }
    let service = makeService?(config) ?? MockPiholeService()
    return try await block(service)
  }
}
