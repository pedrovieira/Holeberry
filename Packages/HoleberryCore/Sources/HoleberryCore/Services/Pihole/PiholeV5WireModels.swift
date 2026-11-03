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
    case .number(let value):
      return Int(exactly: value).map(String.init) ?? String(value)
    case .bool(let value): return value ? "true" : "false"
    case .null: return ""
    }
  }
}

/// Separate from the display decoder: decision evidence never substitutes the current date.
struct V5DomainQueryHistoryResponse: Decodable {
  let data: [V5DomainQueryRow]
}

struct V5ClientNamesResponse: Decodable {
  let clients: [V5ClientName]
}

struct V5ClientName: Decodable {
  let name: String
  // swiftlint:disable:next identifier_name
  let ip: String
}

struct V5DomainQueryRow: Decodable {
  let timestamp: Date
  let queryType: String
  let domain: String
  let client: String
  let status: String
  let reply: String?

  init(from decoder: any Decoder) throws {
    var row = try decoder.unkeyedContainer()
    let time = try row.decode(V5QueryCell.self).stringValue
    guard let seconds = Double(time), seconds.isFinite else {
      throw PiholeError.decoding("Domain query history has an invalid Unix timestamp")
    }
    timestamp = Date(timeIntervalSince1970: seconds)
    queryType = try row.decode(String.self).uppercased()
    let hostname = try row.decode(String.self)
    // Query logs also contain the DNS root and names unsuitable as browser hosts.
    // Preserve them for local filtering; validate only the requested mutation target.
    let name = hostname != "." && hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
    domain = PiholeDomain.identity(name)
    client = try row.decode(String.self)
    status = try row.decode(V5QueryCell.self).stringValue
    guard !domain.isEmpty, !queryType.isEmpty, !client.isEmpty, !status.isEmpty else {
      throw PiholeError.decoding("Domain query history has an empty required field")
    }
    if !row.isAtEnd { _ = try row.decode(V5QueryCell.self) }  // DNSSEC status
    reply = row.isAtEnd ? nil : try row.decode(V5QueryCell.self).stringValue
  }

  func matches(domain identity: String, interval: DateInterval) -> Bool {
    domain == identity && timestamp >= interval.start && timestamp < interval.end
  }

  func entry(clientIP: String) -> DomainQueryEntry {
    DomainQueryEntry(
      domain: domain,
      timestamp: timestamp,
      queryType: queryType,
      clientIP: clientIP,
      handling: handling,
      status: status,
      reply: reply)
  }

  private var handling: DomainQueryHandling {
    switch status {
    case "1", "4", "5", "9", "10", "11": return .ruleBlocked
    case "6", "7", "8", "18": return .upstreamBlocked
    case "2", "3", "12", "13", "17":
      // Unknown/no reply and resolver failures cannot establish permitted processing.
      guard let reply, ["1", "2", "3", "4", "5", "6", "10", "13"].contains(reply) else {
        return .inconclusive
      }
      return .permitted
    default: return .inconclusive
    }
  }
}
