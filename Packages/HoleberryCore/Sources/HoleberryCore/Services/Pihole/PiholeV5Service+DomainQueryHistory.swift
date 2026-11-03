import Darwin
import Foundation

extension PiholeV5Service {
  public func getDomainQueryHistory(
    domain: String, forClientIP: String, interval: DateInterval
  ) async throws -> DomainQueryHistory {
    try Task.checkCancellation()
    let identity = try PiholeDomain.validatedIdentity(domain)
    // v5 selects either time, domain or client filtering. Use integer bounds
    // covering the captured interval, then enforce its precise limits locally.
    guard let from = Int(exactly: interval.start.timeIntervalSince1970.rounded(.down)),
      let until = Int(exactly: interval.end.timeIntervalSince1970.rounded(.up))
    else {
      throw PiholeError.unknown("Invalid domain query history interval")
    }
    let response: V5DomainQueryHistoryResponse = try await queryHistoryResponse(
      params: ["getAllQueries": nil, "from": String(from), "until": String(until)])
    try Task.checkCancellation()
    let rows = response.data.filter { $0.matches(domain: identity, interval: interval) }
    var matches = rows.filter { $0.client == forClientIP }
    // FTL formats a client's visible rows consistently from its current name/IP record.
    // Only look up the captured IP's name when no relevant rows match the IP directly.
    if matches.isEmpty {
      let clientNames = try await verifiedClientNames(in: rows, forClientIP: forClientIP)
      matches = rows.filter {
        !Self.isIPAddress($0.client) && clientNames.contains(Self.clientNameIdentity($0.client))
      }
    }
    try Task.checkCancellation()
    let entries = matches.map { $0.entry(clientIP: forClientIP) }
    return DomainQueryHistory(entries: entries, isComplete: true)
  }

  private func verifiedClientNames(in rows: [V5DomainQueryRow], forClientIP: String) async throws -> Set<String> {
    let names = Set(rows.filter { !Self.isIPAddress($0.client) }.map { Self.clientNameIdentity($0.client) })
    guard !names.isEmpty else { return [] }
    let response: V5ClientNamesResponse = try await queryHistoryResponse(params: ["getClientNames": nil])
    try Task.checkCancellation()
    let clientNames = Set(
      response.clients.filter { $0.ip == forClientIP }.map { Self.clientNameIdentity($0.name) })
    guard !clientNames.isEmpty, clientNames.allSatisfy({ !$0.isEmpty && $0 != "hidden" }) else {
      throw PiholeError.decoding("Could not resolve the captured IP address to a client name")
    }
    let matches = names.intersection(clientNames)
    guard
      !response.clients.contains(where: {
        matches.contains(Self.clientNameIdentity($0.name)) && $0.ip != forClientIP
      })
    else {
      throw PiholeError.decoding("Query history client name matches multiple IP addresses")
    }
    return matches
  }

  private func queryHistoryResponse<Response: Decodable>(params: [String: String?]) async throws -> Response {
    let (data, response) = try await getRequest(path: "/admin/api.php", params: params)
    guard response.isSuccess else {
      throw PiholeError.server(response.statusCode, String(data: data, encoding: .utf8))
    }
    do {
      return try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw PiholeError.decoding("Domain query history: \(error.localizedDescription)")
    }
  }

  private static func clientNameIdentity(_ value: String) -> String {
    (value.hasSuffix(".") ? String(value.dropLast()) : value).lowercased()
  }

  private static func isIPAddress(_ value: String) -> Bool {
    var ipv4 = in_addr()
    var ipv6 = in6_addr()
    return value.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
  }
}
