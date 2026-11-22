import Defaults
import Foundation

/// Read-only server metadata for a configuration picker.
///
/// The identifier is the saved server UUID. `name` is the current display name
/// and `detail` adds a hostname or URL only when names are duplicated.
public struct SavedServerMetadata: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let name: String
  public let detail: String?

  public init(id: UUID, name: String, detail: String?) {
    self.id = id
    self.name = name
    self.detail = detail
  }
}

/// Saved-server choices in their saved order.
public enum SavedServerCatalog {
  /// Picker metadata read without network or Keychain access.
  ///
  /// Returns nil when shared storage is not ready, so a picker can offer only
  /// its own non-server choices instead of stale or partial data. The caller
  /// decides how to present that state.
  @MainActor
  public static func metadata(in suite: UserDefaults, suiteName: String) -> [SavedServerMetadata]? {
    guard let readiness = try? SharedStorageMigration.readiness(in: suite, suiteName: suiteName),
      readiness == .ready
    else {
      return nil
    }
    return metadata(for: Defaults[.servers(suite: suite)])
  }

  /// Picker metadata in saved order, with a locator for duplicated names.
  ///
  /// Duplicate names use the hostname when each hostname is different and
  /// otherwise the full saved URL, so every choice has a distinct subtitle.
  public static func metadata(for servers: [ServerConfig]) -> [SavedServerMetadata] {
    let groups = Dictionary(grouping: servers, by: \.displayName)
    return servers.map { server in
      let name = server.displayName
      guard let group = groups[name], group.count > 1 else {
        return SavedServerMetadata(id: server.id, name: name, detail: nil)
      }
      return SavedServerMetadata(
        id: server.id,
        name: name,
        detail: locator(for: server, among: group)
      )
    }
  }

  private static func locator(for server: ServerConfig, among duplicates: [ServerConfig]) -> String {
    let hosts = duplicates.compactMap(\.hostname)
    if let host = server.hostname,
      hosts.count == duplicates.count,
      Set(hosts).count == duplicates.count
    {
      return host
    }
    return server.url
  }
}
