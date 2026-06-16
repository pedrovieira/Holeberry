import Defaults
import Foundation

struct PiholeServer: Codable, Identifiable, Equatable {
  let id: UUID
  var label: String?
  var url: String
  var version: Version?

  enum Version: String, Codable, Sendable {
    case v5 = "v5"
    case v6 = "v6"

    var displayName: String {
      switch self {
      case .v5: return "Pi-hole v5"
      case .v6: return "Pi-hole v6"
      }
    }
  }

  init(id: UUID = UUID(), label: String? = nil, url: String, version: Version? = nil) {
    self.id = id
    self.label = label
    self.url = url
    self.version = version
  }

  static func == (lhs: PiholeServer, rhs: PiholeServer) -> Bool {
    lhs.id == rhs.id
  }
}

extension PiholeServer: Defaults.Serializable {}
