import Foundation

/// Pure hostname expansion and query-evidence decisions for browser actions.
enum BrowserDomainUnblockPolicy {
  static func candidates(for domain: String) throws -> [String] {
    let identity = try canonicalHostname(domain)
    let variant =
      identity.hasPrefix("www.") ? String(identity.dropFirst(4)) : "www.\(identity)"
    // Validate the variant too: removing www. must not produce an empty hostname.
    _ = try PiholeDomain.validatedIdentity(variant)
    return Set([identity, variant]).sorted()
  }

  static func evaluate(
    _ history: DomainQueryHistory, domain: String, clientIP: String, interval: DateInterval
  ) -> DomainQueryDecision {
    guard let identity = try? canonicalHostname(domain) else { return .unavailable }
    let relevantTypes: Set<String> = ["A", "AAAA", "HTTPS"]
    let relevant = history.entries.filter { entry in
      (try? canonicalHostname(entry.domain)) == identity
        && entry.clientIP == clientIP
        && entry.timestamp >= interval.start && entry.timestamp < interval.end
        && relevantTypes.contains(entry.queryType.uppercased())
    }
    let groups = Dictionary(grouping: relevant) { $0.queryType.uppercased() }
    let latest = groups.values.map(latestHandling)

    // A confirmed latest block is enough, even when another type remains unknown.
    if latest.contains(.ruleBlocked) { return .blocked }
    if !history.isComplete || latest.contains(.inconclusive) { return .unavailable }
    if latest.contains(.upstreamBlocked) { return .upstreamBlocked }
    if latest.contains(.permitted) { return .notBlocked }
    return .noHistory
  }

  private static func canonicalHostname(_ domain: String) throws -> String {
    let hostname = domain.hasSuffix(".") ? String(domain.dropLast()) : domain
    guard !hostname.hasSuffix("."), let identity = try? PiholeDomain.validatedIdentity(hostname) else {
      throw PiholeError.invalidDomain(domain)
    }
    return identity
  }

  private static func latestHandling(_ entries: [DomainQueryEntry]) -> DomainQueryHandling {
    guard let newest = entries.max(by: { $0.timestamp < $1.timestamp }) else { return .inconclusive }
    let tied = entries.filter { $0.timestamp == newest.timestamp }
    // Wire order is not part of the evidence contract, so conflicting ties cannot choose a winner.
    guard
      tied.allSatisfy({
        $0.handling == newest.handling && $0.status == newest.status && $0.reply == newest.reply
      })
    else { return .inconclusive }
    return newest.handling
  }
}
