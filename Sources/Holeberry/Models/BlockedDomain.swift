import Foundation

/// A domain that was blocked by Pi-hole, along with when it was blocked.
struct BlockedDomain: Codable, Equatable {
  let domain: String
  let timestamp: Date
}
