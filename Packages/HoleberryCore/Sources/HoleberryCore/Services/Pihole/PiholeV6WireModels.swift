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
    message == "UNIQUE constraint failed: domainlist.domain, domainlist.type"
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
