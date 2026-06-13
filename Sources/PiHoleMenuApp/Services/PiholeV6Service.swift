import Foundation
import OSLog

/// Pi-hole v6 API implementation using session-based auth (X-FTL-SID) and JSON REST endpoints.
final class PiholeV6Service: PiholeServiceProtocol {
  let piHoleVersion = 6

  private let baseURL: URL
  private let session: URLSession
  private let authManager: AuthManager
  private let password: String
  private static let decoder = JSONDecoder()
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "v6-service")

  init(baseURL: URL, session: URLSession, authManager: AuthManager, password: String) {
    self.baseURL = baseURL
    self.session = session
    self.authManager = authManager
    self.password = password
  }

  func checkStatus() async throws -> BlockingStatus {
    let (data, httpResponse) = try await authenticatedRequest(path: "/api/dns/blocking")

    guard httpResponse.statusCode == 200 else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    struct BlockingResponse: Decodable {
      let blocking: Bool?
      let timer: TimeInterval?
    }

    let status: BlockingResponse
    do {
      status = try Self.decoder.decode(BlockingResponse.self, from: data)
    } catch {
      throw PiholeError.decoding(error.localizedDescription)
    }

    if status.blocking == true {
      return .enabled
    }
    return .disabled(remainingSeconds: status.timer)
  }

  func setBlocking(enabled: Bool, duration: TimeInterval?) async throws {
    let body = SetBlockingBody(blocking: enabled, timer: enabled ? nil : duration)
    let bodyData = try JSONEncoder().encode(body)
    let (data, httpResponse) = try await authenticatedRequest(
      path: "/api/dns/blocking", method: .post, bodyData: bodyData
    )

    guard httpResponse.statusCode == 200 else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }
  }

  func getRecentBlocked() async throws -> [String] {
    let (data, httpResponse) = try await authenticatedRequest(path: "/api/stats/recent_blocked")

    guard httpResponse.statusCode == 200 else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    struct RecentBlockedResponse: Decodable {
      let blocked: [String]
    }

    let result: RecentBlockedResponse
    do {
      result = try Self.decoder.decode(RecentBlockedResponse.self, from: data)
    } catch {
      throw PiholeError.decoding(error.localizedDescription)
    }

    return result.blocked
  }

  func getRecentQueries(clientIP: String?) async throws -> [RecentQuery] {
    var path = "/api/queries?length=100"
    if let clientIP {
      path += "&client=\(clientIP)"
    }

    let (data, httpResponse) = try await authenticatedRequest(path: path)

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
    let (data, httpResponse) = try await authenticatedRequest(
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
    let (data, httpResponse) = try await authenticatedRequest(
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

  private func authenticatedRequest(
    path: String,
    method: HTTPMethod = .get,
    bodyData: Data? = nil,
    retryCount: Int = 0
  ) async throws -> (Data, HTTPURLResponse) {
    let url = baseURL.appendingPathComponent(path)
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
      throw PiholeError.unknown("Invalid response for \(path)")
    }

    if httpResponse.statusCode == 401, retryCount < 1 {
      logger.debug("Got 401 on \(path, privacy: .public); re-authenticating and retrying")
      do {
        try await authManager.reauthenticate(password: password)
      } catch {
        throw PiholeError.unauthorized
      }
      return try await authenticatedRequest(path: path, method: method, bodyData: bodyData, retryCount: retryCount + 1)
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
