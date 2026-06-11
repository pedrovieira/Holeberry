import Foundation

/// Abstract interface for Pi-hole API operations. Implemented separately for v5 and v6.
protocol PiholeServiceProtocol: AnyObject {
  var piHoleVersion: Int { get }

  func checkStatus() async throws -> BlockingStatus
  func setBlocking(enabled: Bool, duration: TimeInterval?) async throws
  func getRecentBlocked() async throws -> [String]
  func getRecentQueries(clientIP: String?) async throws -> [RecentQuery]
  func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainEntry
  func deleteDomain(identifiedBy id: Int) async throws
  func deleteDomain(domain: String) async throws
  func getDomains() async throws -> [DomainEntry]
}
