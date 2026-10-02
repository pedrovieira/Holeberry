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

/// Whether an unblock request created a new allow entry or found one already present.
public enum DomainUnblockOutcome: Equatable, Sendable {
  case added
  /// An existing temporary unblock owned by Holeberry was extended.
  case renewed
  /// An existing temporary unblock was made permanent.
  case promoted
  /// `enabled` is unknown when the existing row cannot be read.
  case alreadyPresent(enabled: Bool?)

  @MainActor
  static func resolve(
    for domain: String, addOutcome: DomainAddOutcome, service: any PiholeServiceProviding
  ) async -> Self {
    guard addOutcome == .alreadyPresent else { return .added }
    let existing = try? await service.getDomain(domain, from: .allow)
    return .alreadyPresent(enabled: existing?.enabled)
  }
}

/// Public interface for Pi-hole API operations. Used by `PiholeServerManager`.
/// No `comment` parameter — that's internal (see `PiholeServiceCommentAdding`).
@MainActor
public protocol PiholeServiceProviding: AnyObject, Sendable {
  var id: UUID { get }
  var label: String? { get set }
  var url: String { get set }
  var version: ServerVersion { get set }
  var isPasswordless: Bool { get async }

  // MARK: - Domain operations

  @discardableResult
  func unblockDomain(_ domain: String, duration: TimeInterval?, ownershipID: UUID) async throws -> DomainUnblockOutcome
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


extension PiholeServiceProviding {
  @discardableResult
  public func unblockDomain(_ domain: String, duration: TimeInterval?) async throws -> DomainUnblockOutcome {
    try await unblockDomain(domain, duration: duration, ownershipID: UUID())
  }
}
