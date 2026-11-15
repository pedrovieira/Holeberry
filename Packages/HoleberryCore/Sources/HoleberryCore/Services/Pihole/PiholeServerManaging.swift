import Combine
import Foundation

/// Entry point for operations on configured servers managed by this instance;
/// fan-out calls return per-server results keyed by id.
@MainActor
public protocol PiholeServerManaging: AnyObject, Sendable {
  var servers: [ServerConfig] { get }
  var serversPublisher: Published<[ServerConfig]>.Publisher { get }

  func getBlockingStatus(scope: ServerScope) async -> [UUID: Result<BlockingStatus, PiholeError>]

  /// Single-server health check. Returns nil for an unknown server id.
  func checkServer(id: UUID) async -> Result<BlockingStatus, PiholeError>?
  func setBlocking(enabled: Bool, duration: TimeInterval?) async -> [UUID: Bool]
  func getQuerySummary(scope: ServerScope) async -> [UUID: Result<QuerySummary, PiholeError>]

  /// Triggers a gravity update on all servers; unsupported ones are skipped.
  func updateGravity() async -> [UUID: Result<Void, PiholeError>]
  func getRecentBlocked(forClientIp: String?, interval: DateInterval) async throws -> [BlockedDomain]
}
