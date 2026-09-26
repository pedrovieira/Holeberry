import Foundation

public struct QuerySummary: Sendable {
  public let totalQueries: Int
  public let totalBlocked: Int
  public let gravityLastUpdated: Date?

  public init(totalQueries: Int, totalBlocked: Int, gravityLastUpdated: Date? = nil) {
    self.totalQueries = totalQueries
    self.totalBlocked = totalBlocked
    self.gravityLastUpdated = gravityLastUpdated
  }
}

/// Public interface for Pi-hole API operations. Used by `PiholeServerManager`.
/// No `comment` parameter — that's internal (see `PiholeServiceCommentAdding`).
/// The `ownershipID` token threaded through `unblockDomain` is an internal
/// detail: a stable, opaque UUID that the decorator turns into the entry
/// marker it uses for ownership checks. Callers act on the returned outcome.
@MainActor
public protocol PiholeServiceProviding: AnyObject, Sendable {
  var id: UUID { get }
  var label: String? { get set }
  var url: String { get set }
  var version: ServerVersion { get set }
  var isPasswordless: Bool { get async }

  // MARK: - Domain operations

  func addDomain(_ domain: String, to list: DomainListType) async throws -> DomainListAddResult
  func unblockDomain(_ domain: String, duration: TimeInterval?, ownershipID: UUID) async throws -> UnblockOutcome
  func deleteDomain(domain: String) async throws
  func getDomains() async throws -> [DomainEntry]

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
