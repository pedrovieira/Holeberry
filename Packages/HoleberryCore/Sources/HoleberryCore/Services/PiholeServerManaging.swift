import Combine
import Foundation

/// The surface of `PiholeServerManager` that `ServerStatusPoller` depends on.
@MainActor
public protocol PiholeServerManaging: AnyObject {
  var servers: [ServerConfig] { get }
  var serversPublisher: Published<[ServerConfig]>.Publisher { get }

  func getBlockingStatus() async -> [UUID: BlockingStatus?]
  func setBlocking(enabled: Bool, duration: TimeInterval?) async -> [UUID: Bool]
  func getQuerySummary() async -> [UUID: QuerySummary?]
  func getRecentBlocked(forClientIp: String?, interval: DateInterval) async throws -> [BlockedDomain]
}
