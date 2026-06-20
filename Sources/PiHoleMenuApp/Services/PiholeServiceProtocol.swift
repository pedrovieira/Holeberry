import Foundation

/// Abstract interface for Pi-hole API operations. Implemented separately for v5 and v6.
protocol PiholeServiceProtocol: AnyObject {
  /// Stable server identity.
  var id: UUID { get }
  /// User-assigned display label.
  var label: String? { get set }
  /// Pi-hole admin URL string.
  var url: String { get set }
  /// Detected API version.
  var version: ServerVersion { get set }

  // MARK: - API

  func checkStatus() async throws -> BlockingStatus
  func setBlocking(enabled: Bool, duration: TimeInterval?) async throws
  func getRecentBlocked(count: Int) async throws -> [String]
  func getRecentQueries(clientIP: String?) async throws -> [RecentQuery]
  func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainEntry
  func deleteDomain(identifiedBy id: Int) async throws
  func deleteDomain(domain: String) async throws
  func getDomains() async throws -> [DomainEntry]

  /// Rebuild the URLSession (and AuthManager for v6) when the server URL changes.
  func refreshSession(from urlString: String)

  /// Log out and tear down any authenticated session. No-op for v5.
  func logout() async
}
