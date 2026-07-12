import Foundation

/// A domain that was blocked by Pi-hole, along with when it was last blocked,
/// how many times it was blocked in the queried interval, and which client
/// triggered the most recent block (empty when unknown).
struct BlockedDomain: Codable, Equatable {
  let domain: String
  let timestamp: Date
  let count: Int
  let fromClientIp: String

  init(domain: String, timestamp: Date, count: Int = 1, fromClientIp: String) {
    self.domain = domain
    self.timestamp = timestamp
    self.count = count
    self.fromClientIp = fromClientIp
  }
}
