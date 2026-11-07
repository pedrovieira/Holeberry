import Foundation

/// `/admin/api.php?list=…` response — v5 wraps the domain rows in a `data` array.
struct V5DomainsResponse: Decodable {
  let data: [DomainEntry]
}

/// v5 add/delete replies use a success flag and an optional message.
struct V5DomainMutationResponse: Decodable {
  let success: Bool
  let message: String?

  func addOutcome(for domain: String) throws -> DomainAddOutcome {
    if message == "Added \(domain)" {
      return .added
    }
    if message == "Not adding \(domain) as it is already on the list" {
      return .alreadyPresent
    }
    throw PiholeError.decoding("Domain add did not confirm whether the entry was created")
  }
}

/// `/admin/api.php?summaryRaw` response. v5 serves the FTL stats with
/// float values and snake_case keys.
struct V5SummaryResponse: Decodable {
  let dnsQueriesToday: Double
  let adsBlockedToday: Double
  let gravityLastUpdated: V5GravityLastUpdated?

  enum CodingKeys: String, CodingKey {
    case dnsQueriesToday = "dns_queries_today"
    case adsBlockedToday = "ads_blocked_today"
    case gravityLastUpdated = "gravity_last_updated"
  }
}

struct V5GravityLastUpdated: Decodable {
  let fileExists: Bool
  let absolute: Double?

  enum CodingKeys: String, CodingKey {
    case fileExists = "file_exists"
    case absolute
  }
}

/// `/admin/api.php?getAllQueries` response. The web layer wraps the rows
/// (heterogeneous arrays of strings/numbers) in a `data` object.
struct V5RecentQueriesResponse: Decodable {
  let data: [[V5QueryCell]]
}

/// A single cell of v5's `getAllQueries` rows, which mix strings and numbers.
enum V5QueryCell: Decodable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else {
      self = .null
    }
  }

  /// String form, mirroring `"\(cell)"` on the serialized value.
  var stringValue: String {
    switch self {
    case .string(let value): return value
    case .number(let value): return Double(Int(value)) == value ? String(Int(value)) : String(value)
    case .bool(let value): return value ? "true" : "false"
    case .null: return ""
    }
  }
}
