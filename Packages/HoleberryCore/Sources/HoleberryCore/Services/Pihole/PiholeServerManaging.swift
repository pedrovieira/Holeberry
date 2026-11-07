import Combine
import Foundation

/// Entry point for operations on all servers managed by this instance;
/// fan-out calls return per-server results keyed by id.
@MainActor
public protocol PiholeServerManaging: AnyObject, Sendable {
  var servers: [ServerConfig] { get }
  var serversPublisher: Published<[ServerConfig]>.Publisher { get }

  func displayLabel(for id: UUID) -> String?

  func getBlockingStatus() async -> [UUID: Result<BlockingStatus, PiholeError>]

  /// Single-server health check. Returns nil for an unknown server id.
  func checkServer(id: UUID) async -> Result<BlockingStatus, PiholeError>?
  func setBlocking(enabled: Bool, duration: TimeInterval?) async -> [UUID: Bool]
  func getQuerySummary() async -> [UUID: QuerySummary?]

  /// Triggers a gravity update on all servers; unsupported ones are skipped.
  func updateGravity() async -> [UUID: Result<Void, PiholeError>]
  func getRecentBlocked(forClientIp: String?, interval: DateInterval) async throws -> [BlockedDomain]

  /// Reads each candidate on all currently configured servers, retaining per-server failures.
  func getDomainQueryHistory(
    domains: [String], forClientIP: String, interval: DateInterval
  ) async -> [String: [UUID: Result<DomainQueryHistory, PiholeError>]]

  /// Applies a managed mutation to all currently configured servers.
  func applyDomainUnblock(
    domain: String, duration: TimeInterval?
  ) async -> [UUID: Result<DomainUnblockOutcome, PiholeError>]
}
