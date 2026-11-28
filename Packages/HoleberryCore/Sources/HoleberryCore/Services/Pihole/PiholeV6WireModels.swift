import Foundation

struct V6BlockingResponse: Decodable {
  let blocking: String?
  let timer: TimeInterval?
}

struct V6QueriesResponse: Decodable {
  let queries: [V6QueryEntry]
}

struct V6QueryEntry: Decodable {
  let domain: String
  let time: Double
  let client: V6ClientInfo
}

struct V6ClientInfo: Decodable {
  // swiftlint:disable:next identifier_name
  let ip: String
}

struct V6AddDomainBody: Encodable {
  let domain: String
  let comment: String?
}

struct V6SetBlockingBody: Encodable {
  let blocking: Bool
  let timer: TimeInterval?
}

public struct DomainsResponse: Decodable {
  let domains: [DomainEntry]
}

/// `/api/stats/summary` response. `gravity` is optional because some FTL
/// builds omit it; `last_update` is 0 before the first gravity run.
struct V6SummaryResponse: Decodable {
  let queries: V6SummaryQueries
  let gravity: V6SummaryGravity?
}

struct V6SummaryGravity: Decodable {
  let lastUpdate: Double?

  enum CodingKeys: String, CodingKey {
    case lastUpdate = "last_update"
  }
}

struct V6SummaryQueries: Decodable {
  let total: Int
  let blocked: Int
}

/// Domain POST replies include per-item results even when the HTTP status is 201.
struct V6DomainAddResponse: Decodable {
  let processed: V6DomainAddProcessed

  static func isDuplicateError(_ message: String?) -> Bool {
    guard let message else { return false }
    return message == "UNIQUE constraint failed: domainlist.domain, domainlist.type"
      || message == "The item is already present"
  }
}

struct V6DomainAddProcessed: Decodable {
  let success: [V6DomainAddItem]
  let errors: [V6DomainAddItem]
}

struct V6DomainAddItem: Decodable {
  let item: String
  let error: String?
}

/// Newer FTL versions report failed inserts through the top-level error object.
struct V6DomainAddErrorResponse: Decodable {
  let error: V6DomainAddErrorDetails
}

struct V6DomainAddErrorDetails: Decodable {
  let key: String
  let hint: String?
}

/// Version-tolerant metadata; a missing cursor must not permit unstable pagination.
struct V6DomainQueryHistoryResponse: Decodable {
  let queries: [V6DomainQueryRow]
  let cursor: Int?
  let recordsFiltered: Int?
  let cursorWasNull: Bool

  enum CodingKeys: String, CodingKey {
    case queries, cursor, recordsFiltered
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    queries = try container.decode([V6DomainQueryRow].self, forKey: .queries)
    cursor = try container.decodeIfPresent(Int.self, forKey: .cursor)
    recordsFiltered = try container.decodeIfPresent(Int.self, forKey: .recordsFiltered)
    cursorWasNull = container.contains(.cursor) && cursor == nil
    guard cursor.map({ $0 >= 0 }) != false, recordsFiltered.map({ $0 >= 0 }) != false else {
      throw PiholeError.decoding("Domain query history has invalid pagination metadata")
    }
  }
}

struct V6DomainQueryRow: Decodable {
  let domain: String
  let time: Double
  let type: String
  let status: String?
  let client: V6ClientInfo
  let reply: V6DomainQueryReply?

  enum CodingKeys: String, CodingKey {
    case domain, time, type, status, client, reply
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let hostname = try container.decode(String.self, forKey: .domain)
    domain = try PiholeDomain.validatedIdentity(hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname)
    time = try container.decode(Double.self, forKey: .time)
    type = try container.decode(String.self, forKey: .type).uppercased()
    status = try container.decodeIfPresent(String.self, forKey: .status)
    client = try container.decode(V6ClientInfo.self, forKey: .client)
    reply = try container.decodeIfPresent(V6DomainQueryReply.self, forKey: .reply)
    guard time.isFinite, !type.isEmpty, !client.ip.isEmpty else {
      throw PiholeError.decoding("Domain query history has an invalid required field")
    }
  }

  var entry: DomainQueryEntry {
    DomainQueryEntry(
      domain: domain,
      timestamp: Date(timeIntervalSince1970: time),
      queryType: type,
      clientIP: client.ip,
      handling: handling,
      status: status ?? "UNKNOWN",
      reply: reply?.type)
  }

  private var handling: DomainQueryHandling {
    switch status {
    case "GRAVITY", "REGEX", "DENYLIST", "GRAVITY_CNAME", "REGEX_CNAME", "DENYLIST_CNAME":
      return .ruleBlocked
    case "EXTERNAL_BLOCKED_IP", "EXTERNAL_BLOCKED_NULL", "EXTERNAL_BLOCKED_NXRA", "EXTERNAL_BLOCKED_EDE15":
      return .upstreamBlocked
    case "FORWARDED", "CACHE", "CACHE_STALE", "RETRIED", "RETRIED_DNSSEC":
      guard let reply = reply?.type,
        ["NODATA", "NXDOMAIN", "CNAME", "IP", "DOMAIN", "RRNAME", "OTHER", "BLOB"].contains(reply)
      else { return .inconclusive }
      return .permitted
    default: return .inconclusive
    }
  }
}

struct V6DomainQueryReply: Decodable {
  let type: String?
}
