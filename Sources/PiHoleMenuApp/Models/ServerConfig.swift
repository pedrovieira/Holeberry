import Defaults
import Foundation

enum ServerVersion: String, Codable, Sendable, CaseIterable {
  case v5
  case v6

  var displayName: String {
    switch self {
    case .v5: return "Pi-hole v5"
    case .v6: return "Pi-hole v6"
    }
  }
}

struct ServerConfig: Codable, Identifiable, Equatable {
  let id: UUID
  var label: String?
  var url: String
  var version: ServerVersion

  init(id: UUID = UUID(), label: String? = nil, url: String, version: ServerVersion) {
    self.id = id
    self.label = label
    self.url = url
    self.version = version
  }

  static func == (lhs: ServerConfig, rhs: ServerConfig) -> Bool {
    lhs.id == rhs.id
  }
}

extension ServerConfig: Defaults.Serializable {}
