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

  public init(id: UUID = UUID(), label: String? = nil, icon: String? = nil, url: String, version: ServerVersion) {
    self.id = id
    self.label = label
    self.icon = icon
    self.url = url
    self.version = version
  }

  public static func == (lhs: ServerConfig, rhs: ServerConfig) -> Bool {
    lhs.id == rhs.id
  }
}

extension ServerConfig: Defaults.Serializable {}
