import Foundation

struct QuerySummary {
  let totalQueries: Int
  let totalBlocked: Int
}

/// Public interface for Pi-hole API operations. Used by `PiholeServerManager`.
/// No `comment` parameter — that's internal (see `PiholeServiceInternal`).
@MainActor
protocol PiholeServiceProtocol: AnyObject {
  var id: UUID { get }
  var label: String? { get set }
  var url: String { get set }
  var version: ServerVersion { get set }

  // MARK: - Domain operations

  func addDomain(_ domain: String, to list: DomainListType) async throws -> DomainEntry
  func unblockDomain(_ domain: String, duration: TimeInterval?) async throws
  func deleteDomain(domain: String) async throws
  func deleteDomain(identifiedBy id: Int) async throws
  func getDomains() async throws -> [DomainEntry]

  // MARK: - Status & queries

  func checkStatus() async throws -> BlockingStatus
  func getQuerySummary() async throws -> QuerySummary
  func setBlocking(enabled: Bool, duration: TimeInterval?) async throws
  func getRecentBlocked(count: Int) async throws -> [String]
  func getRecentQueries(clientIP: String?) async throws -> [RecentQuery]

  // MARK: - Session

  func login() async throws
  func logout() async
}
