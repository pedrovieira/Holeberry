import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `PiholeServiceCommentAdding` with stub injection, call-count tracking, and failure injection.
@MainActor
final class MockPiholeService: PiholeServiceCommentAdding {
  let id: UUID
  var label: String?
  var url: String
  var version: ServerVersion

  var checkStatusStub: Result<BlockingStatus, any Error> = .success(.enabled)
  private(set) var checkStatusCallCount = 0

  var loginStub: Result<Void, any Error> = .success(())
  private(set) var loginCallCount = 0

  var setBlockingStub: Result<Void, any Error> = .success(())
  private(set) var setBlockingCallCount = 0
  var setBlockingLastEnabled: Bool?
  var setBlockingLastDuration: TimeInterval?

  var getRecentBlockedStub: Result<[BlockedDomain], any Error> = .success([])
  private(set) var getRecentBlockedCallCount = 0

  var getQuerySummaryStub: Result<QuerySummary, any Error> = .success(QuerySummary(totalQueries: 0, totalBlocked: 0))
  private(set) var getQuerySummaryCallCount = 0

  var addDomainStub: Result<DomainEntry, any Error> = .success(
    DomainEntry(id: 1, domain: "test.com", type: 0, comment: nil))
  private(set) var addDomainCallCount = 0
  var addDomainLastDomain: String?
  var addDomainLastList: DomainListType?
  var addDomainLastComment: String?

  var deleteDomainByNameStub: Result<Void, any Error> = .success(())
  private(set) var deleteDomainByNameCallCount = 0

  var getDomainsStub: Result<[DomainEntry], any Error> = .success([])
  private(set) var getDomainsCallCount = 0

  private(set) var logoutCallCount = 0

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

  func getRecentBlocked(forClientIp: String?, interval: DateInterval) async throws -> [BlockedDomain] {
    getRecentBlockedCallCount += 1
    return try getRecentBlockedStub.get()
  }

  func getQuerySummary() async throws -> QuerySummary {
    getQuerySummaryCallCount += 1
    return try getQuerySummaryStub.get()
  }

  func addDomain(_ domain: String, to list: DomainListType) async throws -> DomainEntry {
    try await addDomain(domain, to: list, comment: nil)
  }

  func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainEntry {
    addDomainCallCount += 1
    addDomainLastDomain = domain
    addDomainLastList = list
    addDomainLastComment = comment
    return try addDomainStub.get()
  }

  func unblockDomain(_ domain: String, duration: TimeInterval?) async throws {
    _ = try await addDomain(domain, to: .allow, comment: nil)
  }

  func deleteDomain(domain: String) async throws {
    deleteDomainByNameCallCount += 1
    try deleteDomainByNameStub.get()
  }

  func getDomains() async throws -> [DomainEntry] {
    getDomainsCallCount += 1
    return try getDomainsStub.get()
  }

  func login() async throws {
    loginCallCount += 1
    try loginStub.get()
  }

  func logout() async {
    logoutCallCount += 1
  }
}
