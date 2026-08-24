import Combine
import Foundation

/// The surface of `PiholeServerManager` that `ServerStatusPoller` depends on.
@MainActor
public protocol PiholeServerManaging: AnyObject {
  var servers: [ServerConfig] { get }
  var serversPublisher: Published<[ServerConfig]>.Publisher { get }

  func getBlockingStatus() async -> [UUID: Result<BlockingStatus, PiholeError>]

  /// Single-server health check. Returns nil for an unknown server id.
  func checkServer(id: UUID) async -> Result<BlockingStatus, PiholeError>?
  func setBlocking(enabled: Bool, duration: TimeInterval?) async -> [UUID: Bool]
  func getQuerySummary() async -> [UUID: QuerySummary?]

  /// Triggers a gravity update on all servers; unsupported ones are skipped.
  func updateGravity() async -> [UUID: Result<Void, PiholeError>]
  func getRecentBlocked(forClientIp: String?, interval: DateInterval) async throws -> [BlockedDomain]
}
