import Defaults
import Foundation

public enum ServerVersion: String, Codable, Sendable, CaseIterable {
  case v5
  case v6

  public var displayName: String {
    switch self {
    case .v5: return "Pi-hole v5"
    case .v6: return "Pi-hole v6"
    }
  }
}

public struct ServerConfig: Codable, Identifiable, Equatable {
  public let id: UUID
  public var label: String?
  public var icon: String?
  public var url: String
  public var version: ServerVersion
  /// True when the instance has no password set; no keychain credential is stored.
  /// Defaults to false so legacy configs decode as password-protected.
  public var isPasswordless: Bool

  public init(
    id: UUID = UUID(),
    label: String? = nil,
    icon: String? = nil,
    url: String,
    version: ServerVersion,
    isPasswordless: Bool = false
  ) {
    self.id = id
    self.label = label
    self.icon = icon
    self.url = url
    self.version = version
    self.isPasswordless = isPasswordless
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    label = try container.decodeIfPresent(String.self, forKey: .label)
    icon = try container.decodeIfPresent(String.self, forKey: .icon)
    url = try container.decode(String.self, forKey: .url)
    version = try container.decode(ServerVersion.self, forKey: .version)
    isPasswordless = try container.decodeIfPresent(Bool.self, forKey: .isPasswordless) ?? false
  }

  public static func == (lhs: ServerConfig, rhs: ServerConfig) -> Bool {
    lhs.id == rhs.id
  }
}

extension ServerConfig: Defaults.Serializable {}
