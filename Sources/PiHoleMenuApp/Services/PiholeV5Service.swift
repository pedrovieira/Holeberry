import Foundation
import OSLog

/// Pi-hole v5 API implementation using static token auth and query-string endpoints. HTML parsing for domain lists.
final class PiholeV5Service: PiholeServiceProtocol {
  let piHoleVersion = 5

  private let baseURL: URL
  private let session: URLSession
  private let apiToken: String
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "v5-service")
  private static let decoder = JSONDecoder()

  init(baseURL: URL, session: URLSession, apiToken: String) {
    self.baseURL = baseURL
    self.session = session
    self.apiToken = apiToken
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

  func setBlocking(enabled: Bool, duration: TimeInterval?) async throws {
    if enabled {
      let (data, httpResponse) = try await getRequest(
        path: "/admin/api.php", params: ["enable": nil]
      )
      guard httpResponse.statusCode == 200 else {
        throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
      }
    } else {
      let seconds = duration.map { Int($0) } ?? 0
      let (data, httpResponse) = try await getRequest(
        path: "/admin/api.php", params: ["disable": String(seconds)]
      )
      guard httpResponse.statusCode == 200 else {
        throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
      }
    }
  }

  func getRecentBlocked() async throws -> [String] {
    let (data, httpResponse) = try await getRequest(
      path: "/admin/api.php", params: ["recentBlocked": nil]
    )

    guard httpResponse.statusCode == 200 else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    guard let text = String(data: data, encoding: .utf8) else {
      return []
    }

    let lines = text.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    if !lines.isEmpty {
      return lines
    }

    return try await fallbackRecentBlocked()
  }

  private func fallbackRecentBlocked() async throws -> [String] {
    let queries = try await getRecentQueries(clientIP: nil)
    return
      queries
      .filter { $0.status == "blocked" || $0.status == "0" }
      .map { $0.domain }
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

  func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainEntry {
    let listName = list == .allow ? "white" : "black"
    let (data, httpResponse) = try await getRequest(
      path: "/admin/api.php", params: ["list": listName, "add": domain]
    )

    guard httpResponse.statusCode == 200 else {
      throw PiholeError.server(httpResponse.statusCode, String(data: data, encoding: .utf8))
    }

    return DomainEntry(id: nil, domain: domain, type: list.rawValue, comment: nil)
  }

  func deleteDomain(identifiedBy id: Int) async throws {
    throw PiholeError.unknown("deleteDomain(identifiedBy:) is not supported for Pi-hole v5")
  }

  func deleteDomain(domain: String) async throws {
    let entries = try await getDomains()
    let listName = entries.contains { $0.domain == domain } ? "white" : "black"
    let (data, httpResponse) = try await getRequest(
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
