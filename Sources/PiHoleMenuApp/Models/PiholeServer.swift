import Foundation

struct PiholeServer: Codable {
  var url: URL
  var version: Version
  var trustSelfSigned: Bool

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
}
