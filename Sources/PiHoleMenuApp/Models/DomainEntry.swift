import Foundation

/// A domain in Pi-hole's allow/deny list. `id` is nil for v5 (no server-assigned ID).
struct DomainEntry: Codable, Equatable {
  let id: Int?
  let domain: String
  let type: Int
  let comment: String?
}

/// Whether a domain belongs to the allowlist or denylist. Matches Pi-hole's `type` field (0=allow, 1=deny).
enum DomainListType: Int {
  case allow = 0
  case deny = 1
}
