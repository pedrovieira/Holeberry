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
public final class PiholeV5Service: PiholeAPIProviding {
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
  private var isMutatingDomains = false
  private var domainMutationWaiters: [CheckedContinuation<Void, Never>] = []
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
    struct StatusResponse: Decodable {
      let status: String?
    }
    let status: StatusResponse = try await send(
      params: ["status": nil], context: "Blocking status")

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

    // v5 serves the FTL stats as float values with snake_case keys.
    let response: V5SummaryResponse
    do {
      response = try decodeResponse(
        data: data, response: httpResponse, context: "Query summary")
    } catch PiholeError.decoding {
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

    let response: V5RecentQueriesResponse
    do {
      response = try await send(
        params: params, context: "Recent blocked queries")
    } catch PiholeError.decoding {
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

  /// Adds an exact entry, reading the list first to skip existing entries and classifying the add response message.
  public func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainAddOutcome {
    let identity = try PiholeDomain.validatedIdentity(domain)
    await acquireDomainMutation()
    defer { releaseDomainMutation() }
    try Task.checkCancellation()

    // A duplicate add rewrites the comment, so read the list before writing.
    let entries = try await getDomains(from: list)
    if entries.contains(where: { $0.domain.caseInsensitiveCompare(identity) == .orderedSame }) {
      return .alreadyPresent
    }
    let (data, httpResponse) = try await getRequest(
      path: "/admin/api.php",
      params: ["list": listName(for: list), "add": identity],
      method: .post,
      comment: comment
    )

    let response = try validateDomainMutationResponse(data, httpResponse)
    return try response.addOutcome(for: identity)
  }

  private func acquireDomainMutation() async {
    // v5 classifies an insert using the total domainlist row count. All our
    // adds and deletes must wait so they cannot skew each other's counts.
    if isMutatingDomains {
      await withCheckedContinuation { domainMutationWaiters.append($0) }
    } else {
      isMutatingDomains = true
    }
  }

  private func releaseDomainMutation() {
    if domainMutationWaiters.isEmpty {
      isMutatingDomains = false
    } else {
      domainMutationWaiters.removeFirst().resume()
    }
  }

  public func deleteDomain(_ domain: String, from list: DomainListType) async throws {
    let identity = try PiholeDomain.validatedIdentity(domain)
    await acquireDomainMutation()
    defer { releaseDomainMutation() }
    try Task.checkCancellation()
    // Deleting an entry that is already gone succeeds upstream.
    let (data, httpResponse) = try await getRequest(
      path: "/admin/api.php", params: ["list": listName(for: list), "sub": identity]
    )
    try validateDomainMutationResponse(data, httpResponse)
  }

  @discardableResult
  private func validateDomainMutationResponse(
    _ data: Data, _ httpResponse: HTTPURLResponse
  ) throws -> V5DomainMutationResponse {
    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    guard let response = try? Self.decoder.decode(V5DomainMutationResponse.self, from: data) else {
      throw PiholeError.decoding("Domain operation: expected a success flag and optional message")
    }

    // v5 reports operation errors in JSON without changing the HTTP 200 status.
    guard response.success else {
      throw PiholeError.server(httpResponse.statusCode, response.message)
    }
    return response
  }

  public func getDomains(from list: DomainListType) async throws -> [DomainEntry] {
    try await fetchDomainList(listType: listName(for: list))
  }

  public func getDomain(_ domain: String, from list: DomainListType) async throws -> DomainEntry? {
    // Foundation converts Unicode DNS names to their ASCII (punycode) identity.
    let identity = try PiholeDomain.validatedIdentity(domain)
    let entries = try await getDomains(from: list)
    return entries.first { $0.domain.caseInsensitiveCompare(identity) == .orderedSame }
  }

  /// v5 names the lists white/black in its admin API.
  private func listName(for list: DomainListType) -> String {
    list == .allow ? "white" : "black"
  }

  private func fetchDomainList(listType: String) async throws -> [DomainEntry] {
    // v5 returns {"data":[…]} as JSON; it has never returned HTML (verified v5.5–v5.21).
    let response: V5DomainsResponse = try await send(
      params: ["list": listType],
      context: "Domain list",
      decodingErrorPrefix: "Domain list \(listType)")
    return response.data.map { entry in
      DomainEntry(
        id: entry.id,
        domain: Self.domainIdentity(from: entry.domain),
        type: entry.type,
        comment: entry.comment,
        enabled: entry.enabled
      )
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

  private func send<Response: Decodable>(
    params: [String: String?],
    method: HTTPMethod = .get,
    comment: String? = nil,
    context: String,
    decodingErrorPrefix: String? = nil
  ) async throws -> Response {
    let (data, response) = try await getRequest(
      path: "/admin/api.php", params: params, method: method, comment: comment)
    return try decodeResponse(
      data: data, response: response, context: context, decodingErrorPrefix: decodingErrorPrefix)
  }

  private func decodeResponse<Response: Decodable>(
    data: Data, response: HTTPURLResponse, context: String, decodingErrorPrefix: String? = nil
  ) throws -> Response {
    guard response.isSuccess else {
      throw PiholeError.server(response.statusCode, String(data: data, encoding: .utf8))
    }
    do {
      return try Self.decoder.decode(Response.self, from: data)
    } catch {
      logger.error(
        """
        \(context, privacy: .public) decode failed. Status \(response.statusCode). \
        Error: \(String(describing: error), privacy: .private)
        """
      )
      let prefix = decodingErrorPrefix.map { "\($0): " } ?? ""
      throw PiholeError.decoding("\(prefix)\(error.localizedDescription)")
    }
  }

  private func getRequest(
    path: String, params: [String: String?], method: HTTPMethod = .get, comment: String? = nil
  ) async throws -> (
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
    if method == .post {
      // api.php forwards domain/type to groups.php, which reads the comment from $_POST.
      let allowed = CharacterSet.alphanumerics
      guard let encoded = (comment ?? "").addingPercentEncoding(withAllowedCharacters: allowed) else {
        throw PiholeError.unknown("Invalid domain comment")
      }
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.httpBody = Data("comment=\(encoded)".utf8)
    }

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
