import Foundation

/// A domain in Pi-hole's allow/deny list. v5 and v6 both send a
/// server-assigned `id`; it is nil only when a response omits it.
public struct DomainEntry: Codable, Equatable, Sendable {
  public let id: Int?
  public let domain: String
  public let type: Int
  public let comment: String?
  public let enabled: Bool?

  enum CodingKeys: String, CodingKey {
    case id, domain, type, comment, enabled
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(Int.self, forKey: .id)
    domain = try container.decode(String.self, forKey: .domain)
    comment = try container.decodeIfPresent(String.self, forKey: .comment)

    // v6 returns type as a string ("allow"/"deny"), v5 as integer (0/1).
    if let intType = try? container.decode(Int.self, forKey: .type) {
      type = intType
    } else {
      let stringType = try container.decode(String.self, forKey: .type)
      type = stringType == "deny" ? 1 : 0
    }

    // v6 returns enabled as a Bool, v5 as an Int; absent stays nil.
    if let boolEnabled = try? container.decode(Bool.self, forKey: .enabled) {
      enabled = boolEnabled
    } else if let intEnabled = try? container.decode(Int.self, forKey: .enabled) {
      enabled = intEnabled != 0
    } else {
      enabled = nil
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(id, forKey: .id)
    try container.encode(domain, forKey: .domain)
    try container.encode(type, forKey: .type)
    try container.encodeIfPresent(comment, forKey: .comment)
    try container.encodeIfPresent(enabled, forKey: .enabled)
  }

  /// Convenience initializer for synthetic entries.
  public init(id: Int?, domain: String, type: Int, comment: String?, enabled: Bool? = nil) {
    self.id = id
    self.domain = domain
    self.type = type
    self.comment = comment
    self.enabled = enabled
  }
}

/// Whether a domain belongs to the allowlist or denylist. Matches Pi-hole's `type` field (0=allow, 1=deny).
public enum DomainListType: Int, Sendable {
  case allow = 0
  case deny = 1
}
