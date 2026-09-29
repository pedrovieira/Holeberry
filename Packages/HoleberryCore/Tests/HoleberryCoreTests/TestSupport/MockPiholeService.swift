import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `PiholeServiceCommentAdding` with stub injection, call-count tracking, and failure injection.
@MainActor
final class MockPiholeService: PiholeServiceCommentAdding {
  let id: UUID
  var label: String?
  var url: String
  var version: ServerVersion
  /// Simulated password-less state reported to the manager.
  var isPasswordless = false

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

  var updateGravityStub: Result<Void, any Error> = .success(())
  private(set) var updateGravityCallCount = 0

  var addDomainStub: Result<DomainEntry, any Error> = .success(
    DomainEntry(id: 1, domain: "test.com", type: 0, comment: nil))
  private(set) var addDomainCallCount = 0
  var addDomainLastDomain: String?
  var addDomainLastList: DomainListType?
  var addDomainLastComment: String?

  var deleteDomainByNameStub: Result<Void, any Error> = .success(())
  private(set) var deleteDomainByNameCallCount = 0
  var deleteDomainLastDomain: String?
  var deleteDomainLastList: DomainListType?

  var getDomainsStub: Result<[DomainEntry], any Error> = .success([])
  /// Consumed before `getDomainsStub` when non-empty, so a test can answer
  /// successive reads differently (reconciliation, then the expiry probe).
  var getDomainsStubQueue: [Result<[DomainEntry], any Error>] = []
  private(set) var getDomainsCallCount = 0
  /// List passed to the most recent `getDomains(from:)` call.
  var getDomainsLastList: DomainListType?

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

  func updateGravity() async throws {
    updateGravityCallCount += 1
    try updateGravityStub.get()
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

  func deleteDomain(_ domain: String, from list: DomainListType) async throws {
    deleteDomainByNameCallCount += 1
    deleteDomainLastDomain = domain
    deleteDomainLastList = list
    try deleteDomainByNameStub.get()
  }

  func getDomains(from list: DomainListType) async throws -> [DomainEntry] {
    getDomainsLastList = list
    return try nextGetDomainsResult()
  }

  private func nextGetDomainsResult() throws -> [DomainEntry] {
    getDomainsCallCount += 1
    if !getDomainsStubQueue.isEmpty {
      return try getDomainsStubQueue.removeFirst().get()
    }
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
