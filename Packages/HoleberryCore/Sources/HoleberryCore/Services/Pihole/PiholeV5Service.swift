import Foundation
import OSLog

private enum V5QueryStatus: String, CaseIterable {
  case gravity = "1"
  case wildcard = "4"
  case exactBlocklist = "5"
  case regexBlocklist = "6"

  /// Status codes that indicate a query was blocked.
  static let blocked: Set<String> = Set(V5QueryStatus.allCases.map(\.rawValue))
}

/// Pi-hole v5 API implementation using static token auth and query-string endpoints.
public final class PiholeV5Service: PiholeServiceCommentAdding {
  // MARK: - Identity & Config
  public let id: UUID
  public var label: String?
  public var url: String
  public var version: ServerVersion
  public var isPasswordless: Bool { apiToken.isEmpty }

  // MARK: - API
  private var baseURL: URL
  private var session: any HTTPRequestable
  private let apiToken: String
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "v5-service")
  private static let decoder = JSONDecoder()
  /// Safety cap on the number of rows the server returns. The real filter is the time
  /// range (`from`/`until`) and status, but we keep a large limit so v5.0–5.1 servers
  /// (which ignore those params) still bound their response.
  private static let queryLimit = 5000


  public init(
    id: UUID,
    label: String?,
    url: String,
    version: ServerVersion,
    baseURL: URL,
    session: any HTTPRequestable,
    apiToken: String
  ) {
    self.id = id
    self.label = label
    self.url = url
    self.version = version
    self.baseURL = baseURL
    self.session = session
    self.apiToken = apiToken
  }

  public func login() async throws {
    // V5 uses API token — no session to establish.
    // If the token is invalid, the first API call will fail naturally.
  }

  public func logout() async {
    // v5 has no session-based auth — just tear down the session
    session.invalidateAndCancel()
  }


  public func checkStatus() async throws -> BlockingStatus {
    let (data, httpResponse) = try await getRequest(path: "/admin/api.php", params: ["status": nil])

    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    struct StatusResponse: Decodable {
      let status: String?
    }
    let status: StatusResponse
    do {
      status = try Self.decoder.decode(StatusResponse.self, from: data)
    } catch {
      throw PiholeError.decoding(error.localizedDescription)
    }

    guard let rawStatus = status.status else {
      // Unauthenticated v5 returns 200 `{}` (gated on $auth, not HTTP status).
      throw PiholeError.unauthorized
    }

    if rawStatus == "enabled" {
      return .enabled
    }
    return .disabled(remainingSeconds: nil)
  }
  // MARK: - Summary

  public func getQuerySummary() async throws -> QuerySummary {
    let (data, httpResponse) = try await getRequest(
      path: "/admin/api.php", params: ["summaryRaw": nil]
    )

    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    // v5 serves the FTL stats as float values with snake_case keys
    let response: V5SummaryResponse
    do {
      response = try Self.decoder.decode(V5SummaryResponse.self, from: data)
    } catch {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw PiholeError.decoding("Unexpected summary format: \(body)")
    }

    guard let totalQueries = Int(exactly: response.dnsQueriesToday),
      let totalBlocked = Int(exactly: response.adsBlockedToday)
    else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw PiholeError.decoding("Unexpected summary format: \(body)")
    }

    let gravityLastUpdated: Date?
    if let gravity = response.gravityLastUpdated,
      gravity.fileExists,
      let absolute = gravity.absolute
    {
      gravityLastUpdated = Date(timeIntervalSince1970: absolute)
    } else {
      gravityLastUpdated = nil
    }

    return QuerySummary(
      totalQueries: totalQueries,
      totalBlocked: totalBlocked,
      gravityLastUpdated: gravityLastUpdated
    )
  }

  public func updateGravity() async throws {
    // v5 has no token-authenticated gravity trigger (the web UI's internal
    // script requires a PHP session cookie). Supported automation is
    // server-side only (cron / `pihole -g`).
    throw PiholeError.unsupported("Gravity updates via API are not supported by Pi-hole v5")
  }

  public func setBlocking(enabled: Bool, duration: TimeInterval?) async throws {
    if enabled {
      let (data, httpResponse) = try await getRequest(
        path: "/admin/api.php", params: ["enable": nil]
      )
      guard httpResponse.isSuccess else {
        throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
      }
    } else {
      let seconds = duration.map { Int($0) } ?? 0
      let (data, httpResponse) = try await getRequest(
        path: "/admin/api.php", params: ["disable": String(seconds)]
      )
      guard httpResponse.isSuccess else {
        throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
      }
    }
  }

  public func getRecentBlocked(forClientIp: String?, interval: DateInterval) async throws -> [BlockedDomain] {
    // Pass server-side filtering params; silently ignored on FTL < v5.2
    var params: [String: String?] = [
      "getAllQueries": String(Self.queryLimit),
      "from": String(Int(interval.start.timeIntervalSince1970)),
      "until": String(Int(interval.end.timeIntervalSince1970)),
      "status": "1,4,5,6"
    ]
    if let forClientIp {
      params["client"] = forClientIp
    }

    let (data, httpResponse) = try await getRequest(
      path: "/admin/api.php", params: params
    )

    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    guard let response = try? Self.decoder.decode(V5RecentQueriesResponse.self, from: data) else {
      return []
    }
    let rows = response.data

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

    let fromTime = interval.start.timeIntervalSince1970
    let untilTime = interval.end.timeIntervalSince1970

    let blocked = rows.compactMap { row -> BlockedDomain? in
      guard row.count >= 5 else { return nil }
      let status = row[4].stringValue
      guard V5QueryStatus.blocked.contains(status) else { return nil }
      let domain = row[2].stringValue
      let client = row[3].stringValue
      let timestampStr = row[0].stringValue
      let timestamp = dateFormatter.date(from: timestampStr) ?? Date()
      // Client-side time range filter as fallback for FTL < v5.2
      let timestampSecs = timestamp.timeIntervalSince1970
      guard timestampSecs >= fromTime && timestampSecs <= untilTime else { return nil }
      return BlockedDomain(domain: domain, timestamp: timestamp, fromClientIp: client)
    }
    return blocked
  }

  public func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainAddOutcome {
    // A duplicate add rewrites the comment, so read the list before writing.
    let entries = try await getDomains(from: list)
    if entries.contains(where: { $0.domain.caseInsensitiveCompare(domain) == .orderedSame }) {
      return .alreadyPresent
    }
    let (data, httpResponse) = try await getRequest(
      path: "/admin/api.php", params: ["list": listName(for: list), "add": domain]
    )

    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    return .added
  }

  public func unblockDomain(_ domain: String, duration: TimeInterval?) async throws {
    _ = try await addDomain(domain, to: .allow, comment: nil)
  }

  public func deleteDomain(_ domain: String, from list: DomainListType) async throws {
    // Deleting an entry that is already gone succeeds upstream, so this is
    // idempotent for callers.
    let (data, httpResponse) = try await getRequest(
      path: "/admin/api.php", params: ["list": listName(for: list), "sub": domain]
    )
    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }
  }

  public func getDomains(from list: DomainListType) async throws -> [DomainEntry] {
    try await fetchDomainList(listType: listName(for: list))
  }

  /// v5 names the lists white/black in its admin API.
  private func listName(for list: DomainListType) -> String {
    list == .allow ? "white" : "black"
  }

  private func fetchDomainList(listType: String) async throws -> [DomainEntry] {
    let (data, httpResponse) = try await getRequest(
      path: "/admin/api.php", params: ["list": listType]
    )

    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    do {
      // v5 returns {"data":[…]} as JSON; it has never returned HTML (verified v5.5–v5.21).
      let entries = try Self.decoder.decode(V5DomainsResponse.self, from: data).data
      return entries.map { entry in
        DomainEntry(
          id: entry.id,
          domain: Self.domainIdentity(from: entry.domain),
          type: entry.type,
          comment: entry.comment,
          enabled: entry.enabled
        )
      }
    } catch {
      throw PiholeError.decoding("Domain list \(listType): \(error.localizedDescription)")
    }
  }

  /// v5 returns IDNs as HTML-escaped Unicode followed by the ASCII identity
  /// in parentheses, e.g. `b&uuml;cher.de (xn--bcher-kva.de)` (`groups.php`).
  private static func domainIdentity(from value: String) -> String {
    guard value.hasSuffix(")"), let open = value.lastIndex(of: "(") else { return value }
    let ascii = value[value.index(after: open)..<value.index(before: value.endIndex)]
    let labels = ascii.split(separator: ".")
    guard labels.contains(where: { $0.hasPrefix("xn--") }), !ascii.contains(" ") else { return value }
    return String(ascii)
  }

  private func getRequest(path: String, params: [String: String?], method: HTTPMethod = .get) async throws -> (
    Data, HTTPURLResponse
  ) {
    var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
    var queryItems: [URLQueryItem] = [URLQueryItem(name: "auth", value: apiToken)]

    for (key, value) in params {
      if let value {
        queryItems.append(URLQueryItem(name: key, value: value))
      } else {
        queryItems.append(URLQueryItem(name: key, value: nil))
      }
    }

    components?.queryItems = queryItems

    guard let url = components?.url else {
      throw PiholeError.unknown("Invalid URL for path: \(path)")
    }

    var request = URLRequest(url: url)
    request.httpMethod = method.rawValue
    request.timeoutInterval = 15

    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw PiholeError.network(error.localizedDescription)
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw PiholeError.unknown("Invalid response for \(path)")
    }
    return (data, httpResponse)
  }
}

/// `/admin/api.php?list=…` response — v5 wraps the domain rows in a `data` array.
private struct V5DomainsResponse: Decodable {
  let data: [DomainEntry]
}

/// `/admin/api.php?summaryRaw` response. v5 serves the FTL stats with
/// float values and snake_case keys.
private struct V5SummaryResponse: Decodable {
  let dnsQueriesToday: Double
  let adsBlockedToday: Double
  let gravityLastUpdated: V5GravityLastUpdated?

  enum CodingKeys: String, CodingKey {
    case dnsQueriesToday = "dns_queries_today"
    case adsBlockedToday = "ads_blocked_today"
    case gravityLastUpdated = "gravity_last_updated"
  }
}

private struct V5GravityLastUpdated: Decodable {
  let fileExists: Bool
  let absolute: Double?

  enum CodingKeys: String, CodingKey {
    case fileExists = "file_exists"
    case absolute
  }
}

/// `/admin/api.php?getAllQueries` response. The web layer wraps the rows
/// (heterogeneous arrays of strings/numbers) in a `data` object.
private struct V5RecentQueriesResponse: Decodable {
  let data: [[V5QueryCell]]
}

/// A single cell of v5's `getAllQueries` rows, which mix strings and numbers.
private enum V5QueryCell: Decodable {
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
