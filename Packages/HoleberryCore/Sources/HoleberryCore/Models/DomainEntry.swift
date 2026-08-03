import Foundation

/// A domain in Pi-hole's allow/deny list. `id` is nil for v5 (no server-assigned ID).
public struct DomainEntry: Codable, Equatable, Sendable {
  public let id: Int?
  public let domain: String
  public let type: Int
  public let comment: String?

  enum CodingKeys: String, CodingKey {
    case id, domain, type, comment
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
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(id, forKey: .id)
    try container.encode(domain, forKey: .domain)
    try container.encode(type, forKey: .type)
    try container.encodeIfPresent(comment, forKey: .comment)
  }

  /// Convenience initializer used by v5 HTML parsing.
  public init(id: Int?, domain: String, type: Int, comment: String?) {
    self.id = id
    self.domain = domain
    self.type = type
    self.comment = comment
  }
}

/// Whether a domain belongs to the allowlist or denylist. Matches Pi-hole's `type` field (0=allow, 1=deny).
public enum DomainListType: Int {
  case allow = 0
  case deny = 1
}
