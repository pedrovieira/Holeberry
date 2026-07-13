import Foundation
import OSLog

/// Pi-hole v6 API implementation using session-based auth (X-FTL-SID) and JSON REST endpoints.
final class PiholeV6Service: PiholeServiceInternal {
  private static let blockedStatus = "GRAVITY"
  /// Safety cap on the number of rows the server returns. The real filter is the time
  /// range (`from`/`until`), but a large limit prevents unbounded responses.
  private static let queryLimit = 5000

  // MARK: - Identity & Config
  let id: UUID
  var label: String?
  var url: String
  var version: ServerVersion

  // MARK: - API
  private var baseURL: URL
  private var urlSession: URLSession
  private let authSession: AuthSessionProviding
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

  init(
    id: UUID,
    label: String?,
    url: String,
    version: ServerVersion,
    baseURL: URL,
    urlSession: URLSession,
    authSession: AuthSessionProviding
  ) {
    self.id = id
    self.label = label
    self.url = url
    self.version = version
    self.baseURL = baseURL
    self.urlSession = urlSession
    self.authSession = authSession
  }

  func login() async throws {
    try await authSession.login()
  }

  func logout() async {
    await authSession.logout()
    urlSession.invalidateAndCancel()
  }

  func checkStatus() async throws -> BlockingStatus {
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

  func setBlocking(enabled: Bool, duration: TimeInterval?) async throws {
    let body = SetBlockingBody(blocking: enabled, timer: enabled ? nil : duration)
    let (data, httpResponse) = try await authenticatedRequestWithRetry(
      path: "/api/dns/blocking", method: .post, body: body
    )

    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }
  }

  func getRecentBlocked(forClientIp: String?, interval: DateInterval) async throws -> [BlockedDomain] {
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

  func getQuerySummary() async throws -> QuerySummary {
    let (data, httpResponse) = try await authenticatedRequest(path: "/api/stats/summary")

    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let queries = json["queries"] as? [String: Any],
      let totalQueries = queries["total"] as? Int,
      let totalBlocked = queries["blocked"] as? Int
    else {
      let body = String(data: data, encoding: .utf8) ?? ""
      logger.error("Query summary decode failed. Body: \(body, privacy: .public)")
      throw PiholeError.decoding("Unexpected summary format")
    }

    return QuerySummary(
      totalQueries: totalQueries,
      totalBlocked: totalBlocked
    )
  }


  func addDomain(_ domain: String, to list: DomainListType) async throws -> DomainEntry {
    try await addDomain(domain, to: list, comment: nil)
  }

  func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainEntry {
    let body = AddDomainBody(domain: domain, comment: comment)
    let listType = list == .allow ? "allow" : "deny"
    let path = "/api/domains/\(listType)/exact"
    let (data, httpResponse) = try await authenticatedRequestWithRetry(
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

  func deleteDomain(domain: String) async throws {
    // Holeberry only ever adds to allow/exact, so delete from there directly.
    let kind = "exact"
    guard let encodedDomain = domain.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
      throw PiholeError.unknown("Invalid domain: \(domain)")
    }
    let path = "/api/domains/allow/\(kind)/\(encodedDomain)"
    logger.debug("deleteDomain(domain:) DELETE \(path)")
    let (data, httpResponse) = try await authenticatedRequestWithRetry(path: path, method: .delete)

    guard httpResponse.isSuccess else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }
  }

  func unblockDomain(_ domain: String, duration: TimeInterval?) async throws {
    _ = try await addDomain(domain, to: .allow, comment: nil)
  }

  func getDomains() async throws -> [DomainEntry] {
    let (data, httpResponse) = try await authenticatedRequest(path: "/api/domains")

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
        GET /api/domains decode failed. Status \(httpResponse.statusCode). \
        Error: \(String(describing: error)). Body: \(body, privacy: .public)
        """
      )
      throw PiholeError.decoding(error.localizedDescription)
    }
  }

  private static let maxRetries = 3
  private static let backoffSeconds: [TimeInterval] = [1, 2, 4]

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

  /// Retry on server errors (5xx) — 401 retry is handled inside AuthV6SessionProvider.
  private func authenticatedRequestWithRetry(
    path: String,
    method: HTTPMethod,
    body: (any Encodable)? = nil
  ) async throws -> (Data, HTTPURLResponse) {
    var lastError: Error?
    for attempt in 0..<Self.maxRetries {
      do {
        return try await authenticatedRequest(
          path: path, method: method, body: body
        )
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

  private func authenticatedRequest(
    path: String,
    method: HTTPMethod = .get,
    body: (any Encodable)? = nil
  ) async throws -> (Data, HTTPURLResponse) {
    let url = baseURL.appendingPathComponent(path)
    return try await authenticatedRequest(url: url, method: method, body: body)
  }

  private func authenticatedRequest(
    url: URL,
    method: HTTPMethod = .get,
    body: (any Encodable)? = nil
  ) async throws -> (Data, HTTPURLResponse) {
    let bodyData = try body.map { try Self.encoder.encode($0) }
    return try await authSession.authorizedRequest { sid in
      var request = URLRequest(url: url)
      request.httpMethod = method.rawValue
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.timeoutInterval = 15
      request.setValue(sid, forHTTPHeaderField: "X-FTL-SID")

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

struct DomainsResponse: Decodable {
  let domains: [DomainEntry]
}

private struct AddDomainBody: Encodable {
  let domain: String
  let comment: String?
}
