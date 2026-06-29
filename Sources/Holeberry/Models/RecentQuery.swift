import Foundation

/// A single DNS query entry from Pi-hole's query log, with both v5- and v6-compatible key mapping.
struct RecentQuery: Codable, Equatable {
  let timestamp: Date
  let domain: String
  let clientIP: String?
  let status: String?
  let dnsType: String?

  enum CodingKeys: String, CodingKey {
    case timestamp
    case domain
    case clientIP = "client"
    case status
    case dnsType = "type"
  }
}
