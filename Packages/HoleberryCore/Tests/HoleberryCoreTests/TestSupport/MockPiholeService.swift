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

  var addDomainStub: Result<DomainAddOutcome, any Error> = .success(.added)
  var addDomainStubQueue: [Result<DomainAddOutcome, any Error>] = []
  private(set) var unblockDomainOwnershipIDs: [UUID] = []
  var unblockDomainHandler: ((String, TimeInterval?) async throws -> DomainUnblockOutcome)?
  private(set) var addDomainCallCount = 0
  var addDomainLastDomain: String?
  var addDomainLastList: DomainListType?
  var addDomainLastComment: String?

  var deleteDomainStub: Result<Void, any Error> = .success(())
  private(set) var deleteDomainCallCount = 0
  var deleteDomainLastDomain: String?
  var deleteDomainLastList: DomainListType?

  var getDomainsStub: Result<[DomainEntry], any Error> = .success([])
  /// Consumed before `getDomainsStub` when non-empty, so a test can answer
  /// successive reads differently.
  var getDomainsStubQueue: [Result<[DomainEntry], any Error>] = []
  private(set) var getDomainsCallCount = 0
  /// List passed to the most recent `getDomains(from:)` call.
  var getDomainsLastList: DomainListType?

  var getDomainStub: Result<DomainEntry?, any Error> = .success(nil)
  var getDomainHandler: ((String) throws -> DomainEntry?)?
  private(set) var getDomainCallCount = 0
  var getDomainLastDomain: String?
  var getDomainLastList: DomainListType?

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

  func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainAddOutcome {
    addDomainCallCount += 1
    addDomainLastDomain = domain
    addDomainLastList = list
    addDomainLastComment = comment
    if !addDomainStubQueue.isEmpty { return try addDomainStubQueue.removeFirst().get() }
    return try addDomainStub.get()
  }

  @discardableResult
  func unblockDomain(_ domain: String, duration: TimeInterval?, ownershipID: UUID) async throws -> DomainUnblockOutcome
  {
    unblockDomainOwnershipIDs.append(ownershipID)
    if let unblockDomainHandler { return try await unblockDomainHandler(domain, duration) }
    let outcome = try await addDomain(domain, to: .allow, comment: nil)
    return await DomainUnblockOutcome.resolve(for: domain, addOutcome: outcome, service: self)
  }

  func deleteDomain(_ domain: String, from list: DomainListType) async throws {
    deleteDomainCallCount += 1
    deleteDomainLastDomain = domain
    deleteDomainLastList = list
    try deleteDomainStub.get()
  }

  func getDomains(from list: DomainListType) async throws -> [DomainEntry] {
    getDomainsLastList = list
    return try nextGetDomainsResult()
  }

  func getDomain(_ domain: String, from list: DomainListType) async throws -> DomainEntry? {
    getDomainCallCount += 1
    getDomainLastDomain = domain
    getDomainLastList = list
    if let getDomainHandler { return try getDomainHandler(domain) }
    return try getDomainStub.get()
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
