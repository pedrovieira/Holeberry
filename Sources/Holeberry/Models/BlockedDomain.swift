import Foundation

/// A domain that was blocked by Pi-hole, along with when it was last blocked
/// and how many times it was blocked in the queried interval.
struct BlockedDomain: Codable, Equatable {
  let domain: String
  let timestamp: Date
  let count: Int

  init(domain: String, timestamp: Date, count: Int = 1) {
    self.domain = domain
    self.timestamp = timestamp
    self.count = count
  }
}
