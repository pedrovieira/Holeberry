import Foundation
import OSLog

/// Pi-hole v6 API implementation using session-based auth (X-FTL-SID) and JSON REST endpoints.
final class PiholeV6Service: PiholeServiceProtocol {
  // MARK: - Identity & Config
  let id: UUID
  var label: String?
  var url: String
  var version: ServerVersion

  // MARK: - API
  private var baseURL: URL
  private var session: URLSession
  private var authManager: AuthManager
  private let password: String
  private static let decoder = JSONDecoder()
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "v6-service")

  init(
    id: UUID,
    label: String?,
    url: String,
    version: ServerVersion,
    baseURL: URL,
    session: URLSession,
    authManager: AuthManager,
    password: String
  ) {
    self.id = id
    self.label = label
    self.url = url
    self.version = version
    self.baseURL = baseURL
    self.session = session
    self.authManager = authManager
    self.password = password
  }

  func refreshSession(from urlString: String) {
    guard let newURL = URL(string: urlString) else { return }
    self.url = urlString
    self.baseURL = newURL
    session.invalidateAndCancel()
    let delegate = CertificateTrustDelegate(trustedHosts: Set([newURL.host].compactMap { $0 }))
    self.session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    self.authManager = AuthManager(baseURL: newURL, session: self.session)
  }

  func logout() async {
    await authManager.logout()
    session.invalidateAndCancel()
  }

  func checkStatus() async throws -> BlockingStatus {
    let (data, httpResponse) = try await authenticatedRequest(path: "/api/dns/blocking")

    guard httpResponse.statusCode == 200 else {
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
    let bodyData = try JSONEncoder().encode(body)
    let (data, httpResponse) = try await authenticatedRequestWithRetry(
      path: "/api/dns/blocking", method: .post, bodyData: bodyData
    )

    guard httpResponse.statusCode == 200 else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }
  }

  // MARK: - Constants

  private static let blockedStatus = "GRAVITY"

  func getRecentBlocked(count: Int) async throws -> [String] {
    let clientIP = localIPAddress()

    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw PiholeError.unknown("Invalid base URL")
    }
    components.path = "/api/queries"
    var queryItems: [URLQueryItem] = [
      URLQueryItem(name: "status", value: Self.blockedStatus),
      URLQueryItem(name: "length", value: String(count))
    ]
    if let clientIP {
      queryItems.append(URLQueryItem(name: "client_ip", value: clientIP))
    }
    components.queryItems = queryItems
    guard let url = components.url else {
      throw PiholeError.unknown("Invalid URL for /api/queries")
    }

    let (data, httpResponse) = try await authenticatedRequest(url: url)

    guard httpResponse.statusCode == 200 else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    struct QueriesResponse: Decodable {
      let queries: [QueryEntry]
    }

    struct QueryEntry: Decodable {
      let domain: String
    }

    let result: QueriesResponse
    do {
      result = try Self.decoder.decode(QueriesResponse.self, from: data)
    } catch {
      throw PiholeError.decoding(error.localizedDescription)
    }

    return result.queries.map(\.domain)
  }

  // MARK: - Summary

  func getQuerySummary() async throws -> QuerySummary {
    let (data, httpResponse) = try await authenticatedRequest(path: "/api/stats/summary")

    guard httpResponse.statusCode == 200 else {
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

  func getRecentQueries(clientIP: String?) async throws -> [RecentQuery] {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw PiholeError.unknown("Invalid base URL")
    }
    components.path = "/api/queries"
    var queryItems: [URLQueryItem] = [URLQueryItem(name: "length", value: "100")]
    if let clientIP {
      queryItems.append(URLQueryItem(name: "client", value: clientIP))
    }
    components.queryItems = queryItems
    guard let url = components.url else {
      throw PiholeError.unknown("Invalid URL for /api/queries")
    }

    let (data, httpResponse) = try await authenticatedRequest(url: url)

    guard httpResponse.statusCode == 200 else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    struct QueriesResponse: Decodable {
      let queries: [RecentQuery]
    }

    let result: QueriesResponse
    do {
      result = try Self.decoder.decode(QueriesResponse.self, from: data)
    } catch {
      throw PiholeError.decoding(error.localizedDescription)
    }

    return result.queries
  }

  func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainEntry {
    let body = AddDomainBody(domain: domain, type: list.rawValue, comment: comment)
    let bodyData = try JSONEncoder().encode(body)
    let (data, httpResponse) = try await authenticatedRequestWithRetry(
      path: "/api/domains", method: .post, bodyData: bodyData
    )

    if httpResponse.statusCode == 409 {
      throw PiholeError.duplicateDomain
    }

    guard httpResponse.statusCode == 200 else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    do {
      return try Self.decoder.decode(DomainEntry.self, from: data)
    } catch {
      throw PiholeError.decoding(error.localizedDescription)
    }
  }

  func deleteDomain(identifiedBy id: Int) async throws {
    let (data, httpResponse) = try await authenticatedRequestWithRetry(
      path: "/api/domains/\(id)", method: .delete
    )

    guard httpResponse.statusCode == 204 else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }
  }

  func deleteDomain(domain: String) async throws {
    let entries = try await getDomains()
    guard let entry = entries.first(where: { $0.domain == domain }),
      let entryID = entry.id
    else {
      throw PiholeError.unknown("Domain not found in allowlist: \(domain)")
    }
    try await deleteDomain(identifiedBy: entryID)
  }

  func getDomains() async throws -> [DomainEntry] {
    let (data, httpResponse) = try await authenticatedRequest(path: "/api/domains")

    guard httpResponse.statusCode == 200 else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    do {
      return try Self.decoder.decode([DomainEntry].self, from: data)
    } catch {
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

  private func authenticatedRequestWithRetry(
    path: String,
    method: HTTPMethod,
    bodyData: Data? = nil
  ) async throws -> (Data, HTTPURLResponse) {
    var lastError: Error?
    for attempt in 0..<Self.maxRetries {
      do {
        return try await authenticatedRequest(
          path: path, method: method, bodyData: bodyData, retryCount: 0
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
    bodyData: Data? = nil,
    retryCount: Int = 0
  ) async throws -> (Data, HTTPURLResponse) {
    let url = baseURL.appendingPathComponent(path)
    return try await authenticatedRequest(url: url, method: method, bodyData: bodyData, retryCount: retryCount)
  }

  private func authenticatedRequest(
    url: URL,
    method: HTTPMethod = .get,
    bodyData: Data? = nil,
    retryCount: Int = 0
  ) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    request.httpMethod = method.rawValue
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 15

    let headers: [String: String]
    do {
      headers = try await authManager.authHeaders()
    } catch PiholeError.unauthorized {
      try await authManager.login(password: password)
      headers = try await authManager.authHeaders()
    }
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }

    if let bodyData {
      request.httpBody = bodyData
    }

    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw PiholeError.network(error.localizedDescription)
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw PiholeError.unknown("Invalid response for \(url.absoluteString)")
    }

    if httpResponse.statusCode == 401, retryCount < 1 {
      logger.debug("Got 401 on \(url.absoluteString, privacy: .public); re-authenticating and retrying")
      do {
        try await authManager.reauthenticate(password: password)
      } catch {
        throw PiholeError.unauthorized
      }
      return try await authenticatedRequest(url: url, method: method, bodyData: bodyData, retryCount: retryCount + 1)
    }

    return (data, httpResponse)
  }
}

private struct SetBlockingBody: Encodable {
  let blocking: Bool
  let timer: TimeInterval?
}

private struct AddDomainBody: Encodable {
  let domain: String
  let type: Int
  let comment: String?
}
