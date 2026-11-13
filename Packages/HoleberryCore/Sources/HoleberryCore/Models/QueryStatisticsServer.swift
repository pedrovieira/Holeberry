import Foundation

/// Stable identity of one configured Pi-hole server for query statistics.
///
/// `ServerConfig` equality compares only `id`, so this type includes the URL and
/// API version as well. Changing either invalidates statistics collected for the
/// previous endpoint.
public struct QueryStatisticsServer: Equatable, Sendable {
  public let id: UUID
  public let url: String
  public let version: ServerVersion

  public init(id: UUID, url: String, version: ServerVersion) {
    self.id = id
    self.url = url
    self.version = version
  }

  public init(server: ServerConfig) {
    self.init(id: server.id, url: server.url, version: server.version)
  }
}
