import Foundation

extension PiholeV6Service {
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
    let (data, response) = try await authenticatedRequest(url: requestURL)
    guard response.isSuccess else {
      throw PiholeError.server(response.statusCode, String(data: data, encoding: .utf8))
    }
    do {
      return try JSONDecoder().decode(V6DomainQueryHistoryResponse.self, from: data)
    } catch {
      throw PiholeError.decoding("Domain query history: \(error.localizedDescription)")
    }
  }
}
