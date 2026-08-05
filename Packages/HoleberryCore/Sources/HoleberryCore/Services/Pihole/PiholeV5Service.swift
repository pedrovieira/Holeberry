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

/// Pi-hole v5 API implementation using static token auth and query-string endpoints. HTML parsing for domain lists.
public final class PiholeV5Service: PiholeServiceCommentAdding {
  // MARK: - Identity & Config
  public let id: UUID
  public var label: String?
  public var url: String
  public var version: ServerVersion

  // MARK: - API
  private var baseURL: URL
  private var session: any HTTPRequestable
  private let apiToken: String
  private let htmlParser: any PiholeV5HTMLParsing
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
    apiToken: String,
    htmlParser: any PiholeV5HTMLParsing
  ) {
    self.id = id
    self.label = label
    self.url = url
    self.version = version
    self.baseURL = baseURL
    self.session = session
    self.apiToken = apiToken
    self.htmlParser = htmlParser
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

    if status.status == "enabled" {
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

    // v5 returns numbers as strings in JSON with snake_case keys
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let queriesTotalStr = json["queries_total"] as? String,
      let adsBlockedStr = json["ads_blocked_today"] as? String,
      let totalQueries = Int(queriesTotalStr),
      let totalBlocked = Int(adsBlockedStr)
    else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw PiholeError.decoding("Unexpected summary format: \(body)")
    }

    return QuerySummary(totalQueries: totalQueries, totalBlocked: totalBlocked)
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

    guard let rows = try JSONSerialization.jsonObject(with: data) as? [[Any]] else {
      return []
    }

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

    let fromTime = interval.start.timeIntervalSince1970
    let untilTime = interval.end.timeIntervalSince1970

    let blocked = rows.compactMap { row -> BlockedDomain? in
      guard row.count >= 5 else { return nil }
      let status = "\(row[4])"
      guard V5QueryStatus.blocked.contains(status) else { return nil }
      let domain = "\(row[2])"
      let client = "\(row[3])"
      let timestampStr = "\(row[0])"
      let timestamp = dateFormatter.date(from: timestampStr) ?? Date()
      // Client-side time range filter as fallback for FTL < v5.2
      let timestampSecs = timestamp.timeIntervalSince1970
      guard timestampSecs >= fromTime && timestampSecs <= untilTime else { return nil }
      return BlockedDomain(domain: domain, timestamp: timestamp, fromClientIp: client)
    }
    return blocked
  }

  public func addDomain(_ domain: String, to list: DomainListType) async throws -> DomainEntry {
    try await addDomain(domain, to: list, comment: nil)
  }

  public func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainEntry {
    let listName = list == .allow ? "white" : "black"
    let (data, httpResponse) = try await getRequest(
      path: "/admin/api.php", params: ["list": listName, "add": domain]
    )

    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    return DomainEntry(id: nil, domain: domain, type: list.rawValue, comment: nil)
  }

  public func unblockDomain(_ domain: String, duration: TimeInterval?) async throws {
    _ = try await addDomain(domain, to: .allow, comment: nil)
  }

  public func deleteDomain(domain: String) async throws {
    let entries = try await getDomains()
    let listName = entries.contains { $0.domain == domain } ? "white" : "black"
    let (data, httpResponse) = try await getRequest(
      path: "/admin/api.php", params: ["list": listName, "sub": domain]
    )

    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }
  }

  public func getDomains() async throws -> [DomainEntry] {
    let allowEntries = try await parseDomainList(listType: "white", typeValue: 0)
    let denyEntries = try await parseDomainList(listType: "black", typeValue: 1)
    return allowEntries + denyEntries
  }

  private func parseDomainList(listType: String, typeValue: Int) async throws -> [DomainEntry] {
    let (data, httpResponse) = try await getRequest(
      path: "/admin/api.php", params: ["list": listType]
    )

    guard httpResponse.isSuccess else {
      return []
    }

    guard let html = String(data: data, encoding: .utf8) else {
      return []
    }

    return htmlParser.parseDomains(from: html, type: typeValue)
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
