import Foundation

/// Raw Pi-hole API operations, including explicit domain adds with optional comments.
@MainActor
public protocol PiholeAPIProviding: AnyObject, Sendable {
  var id: UUID { get }
  var label: String? { get set }
  var url: String { get set }
  var version: ServerVersion { get set }
  var isPasswordless: Bool { get async }

  // MARK: - Domain operations

  func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainAddOutcome
  func deleteDomain(_ domain: String, from list: DomainListType) async throws
  func getDomains(from list: DomainListType) async throws -> [DomainEntry]
  func getDomain(_ domain: String, from list: DomainListType) async throws -> DomainEntry?

  // MARK: - Status & queries

  func checkStatus() async throws -> BlockingStatus
  func getQuerySummary() async throws -> QuerySummary
  func setBlocking(enabled: Bool, duration: TimeInterval?) async throws
  func getRecentBlocked(forClientIp: String?, interval: DateInterval) async throws -> [BlockedDomain]

  // MARK: - Gravity

  /// Triggers a gravity (filter list) update
  func updateGravity() async throws

  // MARK: - Session

  func login() async throws
  func logout() async
}
