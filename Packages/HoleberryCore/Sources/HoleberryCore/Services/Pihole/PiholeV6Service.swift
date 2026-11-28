import Foundation
import OSLog

/// Pi-hole v6 API implementation using session-based auth (X-FTL-SID) and JSON REST endpoints.
public final class PiholeV6Service: PiholeAPIProviding {
  private static let blockedStatus = "GRAVITY"
  /// Safety cap on the number of rows the server returns. The real filter is the time
  /// range (`from`/`until`), but a large limit prevents unbounded responses.
  private static let queryLimit = 5000

  // MARK: - Identity & Config
  public let id: UUID
  public var label: String?
  public var url: String
  public var version: ServerVersion
  public var isPasswordless: Bool {
    get async { await authSession.isPasswordless }
  }

  // MARK: - API
  private var baseURL: URL
  private var urlSession: any HTTPRequestable
  private let authSession: any AuthSessionProviding
  private static let decoder = JSONDecoder()
  private static let encoder = JSONEncoder()
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "v6-service")

  public init(
    id: UUID,
    label: String?,
    url: String,
    version: ServerVersion,
    baseURL: URL,
    urlSession: any HTTPRequestable,
    authSession: any AuthSessionProviding
  ) {
    self.id = id
    self.label = label
    self.url = url
    self.version = version
    self.baseURL = baseURL
    self.urlSession = urlSession
    self.authSession = authSession
  }

  public func login() async throws {
    try await authSession.login()
  }

  public func logout() async {
    await authSession.logout()
    urlSession.invalidateAndCancel()
  }

  public func checkStatus() async throws -> BlockingStatus {
    let status: V6BlockingResponse = try await send(
      url: baseURL.appendingPathComponent("/api/dns/blocking"), context: "Blocking status")

    if status.blocking == "enabled" {
      return .enabled
    }
    return .disabled(remainingSeconds: status.timer)
  }

  public func setBlocking(enabled: Bool, duration: TimeInterval?) async throws {
    let body = V6SetBlockingBody(blocking: enabled, timer: enabled ? nil : duration)
    let (data, httpResponse) = try await authenticatedRequest(
      path: "/api/dns/blocking", method: .post, body: body
    )

    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }
  }

  public func getRecentBlocked(forClientIp: String?, interval: DateInterval) async throws -> [BlockedDomain] {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw PiholeError.unknown("Invalid base URL")
    }
    components.path = "/api/queries"
    var queryItems: [URLQueryItem] = [
      URLQueryItem(name: "status", value: Self.blockedStatus),
      URLQueryItem(name: "length", value: String(Self.queryLimit)),
      URLQueryItem(name: "from", value: String(Int(interval.start.timeIntervalSince1970))),
      URLQueryItem(name: "until", value: String(Int(interval.end.timeIntervalSince1970)))
    ]
    if let forClientIp {
      queryItems.append(URLQueryItem(name: "client_ip", value: forClientIp))
    }
    components.queryItems = queryItems
    guard let url = components.url else {
      throw PiholeError.unknown("Invalid URL for /api/queries")
    }

    let result: V6QueriesResponse = try await send(
      url: url, context: "Recent blocked queries")

    return result.queries.map { entry in
      BlockedDomain(
        domain: entry.domain,
        timestamp: Date(timeIntervalSince1970: entry.time),
        fromClientIp: entry.client.ip
      )
    }
  }

  public func getDomainQueryHistory(
    domain: String, forClientIP: String, interval: DateInterval
  ) async throws -> DomainQueryHistory {
    let identity = try PiholeDomain.validatedIdentity(domain)
    var entries: [DomainQueryEntry] = []
    var cursor: Int?
    for page in 0..<3 {
      try Task.checkCancellation()
      let response = try await queryHistoryPage(
        domain: identity, clientIP: forClientIP, interval: interval, start: page * 50, cursor: cursor)
      try Task.checkCancellation()
      entries += response.queries.compactMap { row in
        guard row.domain == identity, row.client.ip == forClientIP,
          row.time >= interval.start.timeIntervalSince1970, row.time < interval.end.timeIntervalSince1970
        else { return nil }
        return row.entry
      }
      // A null cursor is the explicit privacy-hidden response, not an empty log.
      if response.cursorWasNull { return DomainQueryHistory(entries: entries, isComplete: false) }
      if response.queries.count < 50 || response.recordsFiltered.map({ $0 <= (page + 1) * 50 }) == true {
        return DomainQueryHistory(entries: entries, isComplete: true)
      }
      if page == 0 { cursor = response.cursor }
      // An older response without a cursor cannot support stable pagination.
      if cursor == nil { break }
    }
    return DomainQueryHistory(entries: entries, isComplete: false)
  }

  private func queryHistoryPage(
    domain: String, clientIP: String, interval: DateInterval, start: Int, cursor: Int?
  ) async throws -> V6DomainQueryHistoryResponse {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw PiholeError.unknown("Invalid base URL")
    }
    components.path = "/api/queries"
    components.queryItems = [
      URLQueryItem(name: "domain", value: domain),
      URLQueryItem(name: "client_ip", value: clientIP),
      URLQueryItem(name: "from", value: String(interval.start.timeIntervalSince1970)),
      URLQueryItem(name: "until", value: String(interval.end.timeIntervalSince1970)),
      URLQueryItem(name: "length", value: "50"),
      URLQueryItem(name: "start", value: String(start))
    ]
    if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: String(cursor))) }
    guard let requestURL = components.url else { throw PiholeError.unknown("Invalid domain history URL") }
    return try await send(
      url: requestURL,
      context: "Domain query history",
      decodingErrorPrefix: "Domain query history")
  }

  // MARK: - Summary

  public func getQuerySummary() async throws -> QuerySummary {
    let response: V6SummaryResponse = try await send(
      url: baseURL.appendingPathComponent("/api/stats/summary"),
      context: "Query summary",
      decodingErrorPrefix: "Unexpected summary format")

    return QuerySummary(
      totalQueries: response.queries.total,
      totalBlocked: response.queries.blocked,
      gravityLastUpdated: response.gravity?.lastUpdate.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
    )
  }

  public func updateGravity() async throws {
    // The response body streams `pihole -g` output and only completes when
    // the gravity process exits, so this request can legitimately run for
    // minutes. 900s covers the longest realistic run.
    let (data, httpResponse) = try await authenticatedRequest(
      path: "/api/action/gravity", method: .post, timeoutInterval: 900
    )

    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }
  }

  /// Adds an exact entry, classifying insert outcomes from the HTTP status and JSON response.
  public func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainAddOutcome {
    let body = V6AddDomainBody(domain: try PiholeDomain.validatedIdentity(domain), comment: comment)
    let path = "/api/domains/\(listTypeName(for: list))/exact"
    let (data, httpResponse) = try await authenticatedRequest(
      path: path, method: .post, body: body
    )

    if httpResponse.statusCode == 409 {
      return .alreadyPresent
    }

    // Newer FTL versions report a failed single insert as a 400 database error.
    if httpResponse.statusCode == 400,
      let response = try? Self.decoder.decode(V6DomainAddErrorResponse.self, from: data),
      response.error.key == "database_error",
      V6DomainAddResponse.isDuplicateError(response.error.hint)
    {
      return .alreadyPresent
    }

    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    let response: V6DomainAddResponse
    do {
      response = try Self.decoder.decode(V6DomainAddResponse.self, from: data)
    } catch {
      throw PiholeError.decoding("Domain add: \(error.localizedDescription)")
    }

    // FTL v6.0 returns 201 even when the insert failed. Only processed.success
    // confirms that this request created the entry; domains can include an old row.
    if let failure = response.processed.errors.first {
      if V6DomainAddResponse.isDuplicateError(failure.error) {
        return .alreadyPresent
      }
      throw PiholeError.server(httpResponse.statusCode, failure.error)
    }
    guard response.processed.success.count == 1 else {
      throw PiholeError.decoding("Domain add did not confirm a created entry")
    }
    return .added
  }

  public func deleteDomain(_ domain: String, from list: DomainListType) async throws {
    let url = try domainURL(domain, from: list)
    let (data, httpResponse) = try await authenticatedRequest(url: url, method: .delete)

    // 404 is "Item not found": the entry is already gone, which is the state the
    // caller asked for. Anything else is a real failure.
    guard httpResponse.isSuccess || httpResponse.statusCode == 404 else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }
  }

  public func getDomains(from list: DomainListType) async throws -> [DomainEntry] {
    // Server-side filter. `/exact` (not the read-only `/allow` and `/deny`
    // forms) lines up with v5's `?list=white|black`, which is exact-only too.
    let url = baseURL.appendingPathComponent("/api/domains/\(listTypeName(for: list))/exact")
    return try await getDomains(url: url)
  }

  public func getDomain(_ domain: String, from list: DomainListType) async throws -> DomainEntry? {
    // Foundation converts Unicode DNS names to their ASCII (punycode) identity.
    let identity = try PiholeDomain.validatedIdentity(domain)
    let entries: [DomainEntry]
    do {
      entries = try await getDomains(url: domainURL(identity, from: list))
    } catch PiholeError.server(let code, _) where code == 404 {
      // 404 is "Item not found": no such entry, so `nil` is the honest answer.
      // Same status `deleteDomain` treats as already done.
      return nil
    }
    return entries.first { $0.domain.caseInsensitiveCompare(identity) == .orderedSame }
  }

  private func domainURL(_ domain: String, from list: DomainListType) throws -> URL {
    let identity = try PiholeDomain.validatedIdentity(domain)
    return baseURL.appendingPathComponent("/api/domains/\(listTypeName(for: list))/exact")
      .appendingPathComponent(identity, isDirectory: false)
  }

  private func getDomains(url: URL) async throws -> [DomainEntry] {
    // V6 wraps domains in {"domains":[...]} — decode through the wrapper.
    let response: DomainsResponse = try await send(
      url: url, context: "Domain list")
    return response.domains
  }

  /// v6 names the lists allow/deny in its REST API.
  private func listTypeName(for list: DomainListType) -> String {
    list == .allow ? "allow" : "deny"
  }

  private func send<Response: Decodable>(
    url: URL,
    method: HTTPMethod = .get,
    body: (any Encodable)? = nil,
    timeoutInterval: TimeInterval = 15,
    context: String,
    decodingErrorPrefix: String? = nil
  ) async throws -> Response {
    let (data, response) = try await authenticatedRequest(
      url: url, method: method, body: body, timeoutInterval: timeoutInterval)
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

  private func authenticatedRequest(
    path: String,
    method: HTTPMethod = .get,
    body: (any Encodable)? = nil,
    timeoutInterval: TimeInterval = 15
  ) async throws -> (Data, HTTPURLResponse) {
    let url = baseURL.appendingPathComponent(path)
    return try await authenticatedRequest(url: url, method: method, body: body, timeoutInterval: timeoutInterval)
  }

  private func authenticatedRequest(
    url: URL,
    method: HTTPMethod = .get,
    body: (any Encodable)? = nil,
    timeoutInterval: TimeInterval = 15
  ) async throws -> (Data, HTTPURLResponse) {
    let bodyData = try body.map { try Self.encoder.encode($0) }
    return try await authSession.authorizedRequest { sid in
      var request = URLRequest(url: url)
      request.httpMethod = method.rawValue
      request.timeoutInterval = timeoutInterval

      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      // No SID on password-less servers
      if !sid.isEmpty {
        request.setValue(sid, forHTTPHeaderField: "X-FTL-SID")
      }

      if let bodyData {
        request.httpBody = bodyData
      }

      let (data, response): (Data, URLResponse)
      do {
        (data, response) = try await urlSession.data(for: request)
      } catch {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
          throw CancellationError()
        }
        throw PiholeError.network(error.localizedDescription)
      }

      guard let httpResponse = response as? HTTPURLResponse else {
        throw PiholeError.unknown("Invalid response for \(url.absoluteString)")
      }

      return ((data, httpResponse), httpResponse)
    }
  }
}
