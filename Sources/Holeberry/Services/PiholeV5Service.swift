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
final class PiholeV5Service: PiholeServiceInternal {
  // MARK: - Identity & Config
  let id: UUID
  var label: String?
  var url: String
  var version: ServerVersion

  // MARK: - API
  private var baseURL: URL
  private var session: URLSession
  private let apiToken: String
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "v5-service")
  private static let decoder = JSONDecoder()

  private static let maxRetries = 3
  private static let backoffSeconds: [TimeInterval] = [1, 2, 4]

  init(
    id: UUID,
    label: String?,
    url: String,
    version: ServerVersion,
    baseURL: URL,
    session: URLSession,
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

  func refreshSession(from urlString: String) {
    guard let newURL = URL(string: urlString) else { return }
    self.url = urlString
    self.baseURL = newURL
    session.invalidateAndCancel()
    let delegate = CertificateTrustDelegate(trustedHosts: Set([newURL.host].compactMap { $0 }))
    self.session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
  }

  func logout() async {
    // v5 has no session-based auth — just tear down the session
    session.invalidateAndCancel()
  }

  private func shouldRetry(_ error: Error) -> Bool {
    if let piholeError = error as? PiholeError {
      switch piholeError {
      case .network:
        return true
      case .server(let code, _):
        return (500...599).contains(code)
      default:
        return false
      }
    }
    return false
  }

  private func getRequestWithRetry(
    path: String,
    params: [String: String?],
    method: HTTPMethod = .get
  ) async throws -> (Data, HTTPURLResponse) {
    var lastError: Error?
    for attempt in 0..<Self.maxRetries {
      do {
        return try await getRequest(path: path, params: params, method: method)
      } catch {
        lastError = error
        guard shouldRetry(error), attempt < Self.maxRetries - 1 else { throw error }
        logger.debug(
          """
          Retrying \(path) after error (attempt \(attempt + 1)/\(Self.maxRetries)): \
          \(error.localizedDescription, privacy: .public)
          """
        )
        try? await Task.sleep(for: .seconds(Self.backoffSeconds[attempt]))
      }
    }
    throw lastError ?? PiholeError.unknown("Retry exhausted")
  }

  func checkStatus() async throws -> BlockingStatus {
    let (data, httpResponse) = try await getRequest(path: "/admin/api.php", params: ["status": nil])

    guard httpResponse.statusCode == 200 else {
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

  func getQuerySummary() async throws -> QuerySummary {
    let (data, httpResponse) = try await getRequest(
      path: "/admin/api.php", params: ["summaryRaw": nil]
    )

    guard httpResponse.statusCode == 200 else {
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

  func setBlocking(enabled: Bool, duration: TimeInterval?) async throws {
    if enabled {
      let (data, httpResponse) = try await getRequestWithRetry(
        path: "/admin/api.php", params: ["enable": nil]
      )
      guard httpResponse.statusCode == 200 else {
        throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
      }
    } else {
      let seconds = duration.map { Int($0) } ?? 0
      let (data, httpResponse) = try await getRequestWithRetry(
        path: "/admin/api.php", params: ["disable": String(seconds)]
      )
      guard httpResponse.statusCode == 200 else {
        throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
      }
    }
  }

  func getRecentBlocked(count: Int) async throws -> [String] {
    let clientIP = localIPAddress()

    // v5 doesn't support server-side status filtering, so over-fetch and filter client-side
    var params: [String: String?] = ["getAllQueries": String(max(count, 1000))]
    if let clientIP {
      params["client"] = clientIP
    }

    let (data, httpResponse) = try await getRequest(
      path: "/admin/api.php", params: params
    )

    guard httpResponse.statusCode == 200 else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    guard let rows = try JSONSerialization.jsonObject(with: data) as? [[Any]] else {
      return []
    }

    let blocked = rows.compactMap { row -> String? in
      guard row.count >= 5 else { return nil }
      let status = "\(row[4])"
      guard V5QueryStatus.blocked.contains(status) else { return nil }
      return "\(row[2])"
    }
    return Array(blocked.prefix(count))
  }

  func getRecentQueries(clientIP: String?) async throws -> [RecentQuery] {
    let (data, httpResponse) = try await getRequest(
      path: "/admin/api.php", params: ["getAllQueries": nil]
    )

    guard httpResponse.statusCode == 200 else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    guard let rawJSON = try JSONSerialization.jsonObject(with: data) as? [[Any]] else {
      throw PiholeError.decoding("Unexpected v5 getAllQueries format")
    }

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

    var queries: [RecentQuery] = []
    for row in rawJSON {
      guard row.count >= 5 else { continue }
      let timestampStr = "\(row[0])"
      let timestamp = dateFormatter.date(from: timestampStr) ?? Date()
      let dnsType = "\(row[1])"
      let domain = "\(row[2])"
      let clientIP = "\(row[3])"
      let status = "\(row[4])"

      queries.append(
        RecentQuery(
          timestamp: timestamp,
          domain: domain,
          clientIP: clientIP,
          status: status,
          dnsType: dnsType
        ))
    }

    if let clientIP {
      return queries.filter { $0.clientIP == clientIP }
    }
    return queries
  }

  func addDomain(_ domain: String, to list: DomainListType) async throws -> DomainEntry {
    try await addDomain(domain, to: list, comment: nil)
  }

  func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainEntry {
    let listName = list == .allow ? "white" : "black"
    let (data, httpResponse) = try await getRequestWithRetry(
      path: "/admin/api.php", params: ["list": listName, "add": domain]
    )

    guard httpResponse.statusCode == 200 else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    return DomainEntry(id: nil, domain: domain, type: list.rawValue, comment: nil)
  }

  func unblockDomain(_ domain: String, duration: TimeInterval?) async throws {
    _ = try await addDomain(domain, to: .allow, comment: nil)
  }

  func deleteDomain(identifiedBy id: Int) async throws {
    throw PiholeError.unknown("deleteDomain(identifiedBy:) is not supported for Pi-hole v5")
  }

  func deleteDomain(domain: String) async throws {
    let entries = try await getDomains()
    let listName = entries.contains { $0.domain == domain } ? "white" : "black"
    let (data, httpResponse) = try await getRequestWithRetry(
      path: "/admin/api.php", params: ["list": listName, "sub": domain]
    )

    guard httpResponse.statusCode == 200 else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }
  }

  func getDomains() async throws -> [DomainEntry] {
    let allowEntries = try await parseDomainList(listType: "white", typeValue: 0)
    let denyEntries = try await parseDomainList(listType: "black", typeValue: 1)
    return allowEntries + denyEntries
  }

  private func parseDomainList(listType: String, typeValue: Int) async throws -> [DomainEntry] {
    let (data, httpResponse) = try await getRequest(
      path: "/admin/api.php", params: ["list": listType]
    )

    guard httpResponse.statusCode == 200 else {
      return []
    }

    guard let html = String(data: data, encoding: .utf8) else {
      return []
    }

    return Self.parseDomainsFromHTML(html, type: typeValue)
  }

  static func parseDomainsFromHTML(_ html: String, type: Int) -> [DomainEntry] {
    guard let tableRange = html.range(of: "(?i)<table[^>]*>", options: .regularExpression) else {
      return []
    }

    let afterTable = html[tableRange.lowerBound...]
    guard let tableEnd = afterTable.range(of: "</table>", options: .caseInsensitive) else {
      return []
    }

    let tableContent = html[tableRange.lowerBound..<tableEnd.upperBound]

    let pattern = "<tr[^>]*>(.*?)</tr>"
    let rowOptions: NSRegularExpression.Options = [.dotMatchesLineSeparators, .caseInsensitive]
    guard let rowRegex = try? NSRegularExpression(pattern: pattern, options: rowOptions) else {
      return []
    }

    let nsTable = NSString(string: String(tableContent))
    let rowMatches = rowRegex.matches(
      in: String(tableContent),
      options: [],
      range: NSRange(location: 0, length: nsTable.length)
    )

    let cellPattern = "<td[^>]*>(.*?)</td>"
    let cellOptions: NSRegularExpression.Options = [.dotMatchesLineSeparators, .caseInsensitive]
    guard let cellRegex = try? NSRegularExpression(pattern: cellPattern, options: cellOptions) else {
      return []
    }

    var entries: [DomainEntry] = []
    for rowMatch in rowMatches {
      let rowString = nsTable.substring(with: rowMatch.range)
      let nsRow = NSString(string: rowString)
      let cellMatches = cellRegex.matches(in: rowString, options: [], range: NSRange(location: 0, length: nsRow.length))
      guard cellMatches.count >= 1 else { continue }

      let firstCell = nsRow.substring(with: cellMatches[0].range(at: 1))
      let domain = Self.stripHTMLTags(from: firstCell).trimmingCharacters(in: .whitespacesAndNewlines)
      if !domain.isEmpty && domain != "Domain" {
        entries.append(DomainEntry(id: nil, domain: domain, type: type, comment: nil))
      }
    }

    return entries
  }

  private static func stripHTMLTags(from string: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: [.caseInsensitive]) else {
      return string
    }
    let nsString = NSString(string: string)
    let range = NSRange(location: 0, length: nsString.length)
    return regex.stringByReplacingMatches(in: string, range: range, withTemplate: "")
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
