import Foundation

/// A domain that was blocked by Pi-hole, along with when it was last blocked,
/// how many times it was blocked in the queried interval, and which client
/// triggered the most recent block (empty when unknown).
public struct BlockedDomain: Codable, Equatable, Sendable {
  public let domain: String
  public let timestamp: Date
  public let count: Int
  public let fromClientIp: String

  public init(domain: String, timestamp: Date, count: Int = 1, fromClientIp: String) {
    self.domain = domain
    self.timestamp = timestamp
    self.count = count
    self.fromClientIp = fromClientIp
  }
}
