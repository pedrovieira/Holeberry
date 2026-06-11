import Foundation

@testable import PiHoleMenuApp

/// Configurable mock implementing `PiholeServiceProtocol` with stub injection, call-count tracking, and failure injection.
final class MockPiholeService: PiholeServiceProtocol {
  let piHoleVersion: Int

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

  init(piHoleVersion: Int = 6) {
    self.piHoleVersion = piHoleVersion
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

  func getRecentBlocked() async throws -> [String] {
    getRecentBlockedCallCount += 1
    return try getRecentBlockedStub.get()
  }

  func getRecentQueries(clientIP: String?) async throws -> [RecentQuery] {
    getRecentQueriesCallCount += 1
    return try getRecentQueriesStub.get()
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
}
