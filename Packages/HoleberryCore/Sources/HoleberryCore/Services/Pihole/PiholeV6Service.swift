import Foundation
import OSLog

/// Pi-hole v6 API implementation using session-based auth (X-FTL-SID) and JSON REST endpoints.
public final class PiholeV6Service: PiholeServiceCommentAdding {
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

  // MARK: - API response types

  private struct QueriesResponse: Decodable {
    let queries: [QueryEntry]
  }

  private struct QueryEntry: Decodable {
    let domain: String
    let time: Double
    let client: ClientInfo
  }

  private struct ClientInfo: Decodable {
    // swiftlint:disable:next identifier_name
    let ip: String
  }

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
    let (data, httpResponse) = try await authenticatedRequest(path: "/api/dns/blocking")

    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    struct BlockingResponse: Decodable {
      let blocking: String?
      let timer: TimeInterval?
    }

    let status: BlockingResponse
    do {
      status = try Self.decoder.decode(BlockingResponse.self, from: data)
    } catch {
      let body = String(data: data, encoding: .utf8) ?? ""
      self.logger.error(
        "Blocking status decode failed. Status \(httpResponse.statusCode). Body: \(body, privacy: .public)"
      )
      throw PiholeError.decoding(error.localizedDescription)
    }

    if status.blocking == "enabled" {
      return .enabled
    }
    return .disabled(remainingSeconds: status.timer)
  }

  public func setBlocking(enabled: Bool, duration: TimeInterval?) async throws {
    let body = SetBlockingBody(blocking: enabled, timer: enabled ? nil : duration)
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

    let (data, httpResponse) = try await authenticatedRequest(url: url)

    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    let result: QueriesResponse
    do {
      result = try Self.decoder.decode(QueriesResponse.self, from: data)
    } catch {
      let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
      self.logger.error("V6 getRecentBlocked decode failed. URL: \(url.absoluteString, privacy: .public)")
      self.logger.error("Response body (truncated): \(body.prefix(500), privacy: .public)")
      self.logger.error("Decode error: \(error.localizedDescription, privacy: .public)")
      throw PiholeError.decoding(error.localizedDescription)
    }

    return result.queries.map { entry in
      BlockedDomain(
        domain: entry.domain,
        timestamp: Date(timeIntervalSince1970: entry.time),
        fromClientIp: entry.client.ip
      )
    }
  }

  // MARK: - Summary

  public func getQuerySummary() async throws -> QuerySummary {
    let (data, httpResponse) = try await authenticatedRequest(path: "/api/stats/summary")

    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    let response: SummaryResponse
    do {
      response = try Self.decoder.decode(SummaryResponse.self, from: data)
    } catch {
      let body = String(data: data, encoding: .utf8) ?? ""
      logger.error("Query summary decode failed. Body: \(body, privacy: .public)")
      throw PiholeError.decoding("Unexpected summary format: \(error.localizedDescription)")
    }

    let gravityLastUpdated: Date?
    if let lastUpdate = response.gravity?.lastUpdate, lastUpdate > 0 {
      gravityLastUpdated = Date(timeIntervalSince1970: lastUpdate)
    } else {
      gravityLastUpdated = nil
    }

    return QuerySummary(
      totalQueries: response.queries.total,
      totalBlocked: response.queries.blocked,
      gravityLastUpdated: gravityLastUpdated
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

  public func addDomain(_ domain: String, to list: DomainListType) async throws -> DomainEntry {
    try await addDomain(domain, to: list, comment: nil)
  }

  public func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainEntry {
    let body = AddDomainBody(domain: domain, comment: comment)
    let path = "/api/domains/\(listTypeName(for: list))/exact"
    let (data, httpResponse) = try await authenticatedRequest(
      path: path, method: .post, body: body
    )

    if httpResponse.statusCode == 409 {
      throw PiholeError.duplicateDomain
    }

    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    // V6 wraps the response in {"domains":[...]} — our DomainEntry struct
    // can't decode that directly. Since callers ignore the return value,
    // just return a synthetic entry from the known inputs.
    return DomainEntry(id: nil, domain: domain, type: list.rawValue, comment: comment)
  }

  public func addDomainUnlessPresent(
    _ domain: String,
    to list: DomainListType,
    comment: String?
  ) async throws -> DomainAddOutcome {
    do {
      _ = try await addDomain(domain, to: list, comment: comment)
      return .added
    } catch PiholeError.duplicateDomain {
      return .alreadyPresent
    }
  }

  public func deleteDomain(_ domain: String, from list: DomainListType) async throws {
    guard let encodedDomain = domain.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
      throw PiholeError.unknown("Invalid domain: \(domain)")
    }
    let path = "/api/domains/\(listTypeName(for: list))/exact/\(encodedDomain)"
    logger.debug("deleteDomain DELETE \(path)")
    let (data, httpResponse) = try await authenticatedRequest(path: path, method: .delete)

    // 404 is "Item not found": the entry is already gone, which is the state the
    // caller asked for. Anything else is a real failure.
    guard httpResponse.isSuccess || httpResponse.statusCode == 404 else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }
  }

  public func unblockDomain(_ domain: String, duration: TimeInterval?) async throws {
    _ = try await addDomain(domain, to: .allow, comment: nil)
  }

  public func getDomains(from list: DomainListType) async throws -> [DomainEntry] {
    // Server-side filter. `/exact` (not the read-only `/allow` and `/deny`
    // forms) lines up with v5's `?list=white|black`, which is exact-only too.
    try await fetchDomains(path: "/api/domains/\(listTypeName(for: list))/exact")
  }

  private func fetchDomains(path: String) async throws -> [DomainEntry] {
    let (data, httpResponse) = try await authenticatedRequest(path: path)

    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    do {
      // V6 wraps domains in {"domains":[...]} — decode through the wrapper.
      let response = try Self.decoder.decode(DomainsResponse.self, from: data)
      return response.domains
    } catch {
      let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
      logger.error(
        """
        GET \(path, privacy: .public) decode failed. Status \(httpResponse.statusCode). \
        Error: \(String(describing: error)). Body: \(body, privacy: .public)
        """
      )
      throw PiholeError.decoding(error.localizedDescription)
    }
  }

  /// v6 names the lists allow/deny in its REST API.
  private func listTypeName(for list: DomainListType) -> String {
    list == .allow ? "allow" : "deny"
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
        throw PiholeError.network(error.localizedDescription)
      }

      guard let httpResponse = response as? HTTPURLResponse else {
        throw PiholeError.unknown("Invalid response for \(url.absoluteString)")
      }

      return ((data, httpResponse), httpResponse)
    }
  }
}

private struct SetBlockingBody: Encodable {
  let blocking: Bool
  let timer: TimeInterval?
}

public struct DomainsResponse: Decodable {
  let domains: [DomainEntry]
}

private struct AddDomainBody: Encodable {
  let domain: String
  let comment: String?
}

/// `/api/stats/summary` response. `gravity` is optional because some FTL
/// builds omit it; `last_update` is 0 before the first gravity run.
private struct SummaryResponse: Decodable {
  let queries: SummaryQueries
  let gravity: SummaryGravity?
}

private struct SummaryGravity: Decodable {
  let lastUpdate: Double?

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: SummaryGravityKey.self)
    lastUpdate = try container.decodeIfPresent(Double.self, forKey: .lastUpdate)
  }
}

private enum SummaryGravityKey: String, CodingKey {
  case lastUpdate = "last_update"
}

private struct SummaryQueries: Decodable {
  let total: Int
  let blocked: Int
}
