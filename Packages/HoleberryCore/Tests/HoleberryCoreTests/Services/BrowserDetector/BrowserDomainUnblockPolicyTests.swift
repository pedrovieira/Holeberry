import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("Browser domain unblock policy")
struct BrowserDomainUnblockPolicyTests {
  private let end = Date(timeIntervalSince1970: 1_700_000_000)
  private let clientIP = "192.168.1.50"

  private var interval: DateInterval {
    DateInterval(start: end.addingTimeInterval(-900), end: end)
  }

  @Test("Candidates canonicalize case, IDNs and the DNS root dot")
  func candidates() throws {
    #expect(try BrowserDomainUnblockPolicy.candidates(for: "www.example.com") == ["example.com", "www.example.com"])
    #expect(try BrowserDomainUnblockPolicy.candidates(for: "EXAMPLE.COM.") == ["example.com", "www.example.com"])
    #expect(
      try BrowserDomainUnblockPolicy.candidates(for: "shop.example.com")
        == ["shop.example.com", "www.shop.example.com"])
    #expect(
      try BrowserDomainUnblockPolicy.candidates(for: "WWW.BÜCHER.de.")
        == ["www.xn--bcher-kva.de", "xn--bcher-kva.de"])
    #expect(
      try BrowserDomainUnblockPolicy.candidates(for: "xn--bcher-kva.de")
        == ["www.xn--bcher-kva.de", "xn--bcher-kva.de"])
  }

  @Test(
    "IPv4 candidates have no www sibling",
    arguments: [("192.168.1.2", "192.168.1.2"), ("127.0.0.1", "127.0.0.1"), ("192.168.1.2.", "192.168.1.2")]
  )
  func ipv4Candidates(domain: String, expected: String) throws {
    #expect(try BrowserDomainUnblockPolicy.candidates(for: domain) == [expected])
  }

  @Test(
    "Candidates reject malformed hostnames",
    arguments: [
      "", ".", "..", ".example.com", "example..com", "example.com..", "www..example.com",
      "example.com/path", "example.com\\path", "user@example.com", "example.com:80",
      "https://example.com", "example.com?x=1", "example.com#fragment", "example.com%2e", " example.com",
      "::1", "2001:db8::1", "[::1]", "[2001:db8::1]"
    ]
  )
  func invalidCandidates(domain: String) {
    #expect(throws: PiholeError.invalidDomain(domain)) {
      try BrowserDomainUnblockPolicy.candidates(for: domain)
    }
  }

  @Test("ALLOW for the domain inside the requested timeframe", arguments: [900.0, 450.0, 1.0])
  func allowedDomainInRequestedTimeframe(age: TimeInterval) {
    #expect(decision([entry(.permitted, age: age)]) == .notBlocked)
  }

  @Test("DENY for the domain inside the requested timeframe", arguments: [900.0, 450.0, 1.0])
  func deniedDomainInRequestedTimeframe(age: TimeInterval) {
    #expect(decision([entry(.ruleBlocked, age: age)]) == .blocked)
  }

  @Test("Domain absent from the requested timeframe", arguments: [DomainQueryHandling.permitted, .ruleBlocked])
  func domainAbsentFromRequestedTimeframe(handling: DomainQueryHandling) {
    #expect(decision([]) == .noHistory)
    #expect(
      decision([
        entry(handling, age: 900.001),
        entry(handling, age: 0),
        entry(handling, age: -1),
        entry(handling, age: 450, domain: "other.example.com")
      ]) == .noHistory)
  }

  @Test func latestAllowedSupersedesBlock() {
    #expect(decision([entry(.ruleBlocked, age: 20), entry(.permitted, age: 10)]) == .notBlocked)
    #expect(decision([entry(.permitted, age: 20), entry(.ruleBlocked, age: 10)]) == .blocked)
  }

  @Test func blockedAFollowedByAllowedAAAAStillBlocks() {
    #expect(decision([entry(.ruleBlocked, age: 20), entry(.permitted, age: 10, type: "AAAA")]) == .blocked)
    #expect(decision([entry(.permitted, type: "A"), entry(.ruleBlocked, type: "HTTPS")]) == .blocked)
  }

  @Test func otherClientAndOtherHostnameAreIgnored() {
    #expect(
      decision([
        entry(.ruleBlocked, client: "192.168.1.51"),
        entry(.ruleBlocked, domain: "www.example.com"),
        entry(.ruleBlocked, domain: "shop.example.com"),
        entry(.ruleBlocked, domain: "notexample.com"),
        entry(.ruleBlocked, type: "TXT")
      ]) == .noHistory)
    #expect(
      decision([entry(.ruleBlocked), entry(.permitted, age: 1, client: "192.168.1.51")]) == .blocked)
  }

  @Test func conflictingTimestampIsInconclusive() {
    let rows = [entry(.ruleBlocked), entry(.permitted)]
    #expect(decision(rows) == .unavailable)
    #expect(decision(rows.reversed()) == .unavailable)
    #expect(decision([entry(.ruleBlocked), entry(.ruleBlocked)]) == .blocked)
    #expect(decision(rows + [entry(.ruleBlocked, type: "AAAA")]) == .blocked)
  }

  @Test("Permitted ties ignore differences in status or reply", arguments: [true, false])
  func permittedTimestampTie(statusDiffers: Bool) {
    let rows = [
      DomainQueryEntry(
        domain: "example.com", timestamp: end.addingTimeInterval(-10), queryType: "A",
        clientIP: clientIP, handling: .permitted, status: "2", reply: "4"),
      DomainQueryEntry(
        domain: "example.com", timestamp: end.addingTimeInterval(-10), queryType: "A",
        clientIP: clientIP, handling: .permitted, status: statusDiffers ? "3" : "2",
        reply: statusDiffers ? "4" : "1")
    ]
    #expect(decision(rows) == .notBlocked)
    #expect(decision(rows.reversed()) == .notBlocked)
  }

  @Test func unfinishedLatestDoesNotUseOlderBlock() {
    #expect(decision([entry(.ruleBlocked, age: 20), entry(.inconclusive, age: 10)]) == .unavailable)
    #expect(decision([entry(.permitted, type: "AAAA"), entry(.inconclusive)]) == .unavailable)
  }

  @Test func partialHistoryCannotProveNegative() {
    #expect(decision([], complete: false) == .unavailable)
    #expect(decision([entry(.permitted)], complete: false) == .unavailable)
    #expect(decision([entry(.upstreamBlocked)], complete: false) == .unavailable)
    #expect(decision([entry(.ruleBlocked)], complete: false) == .blocked)
  }

  @Test func windowBoundaries() {
    #expect(decision([entry(.ruleBlocked, age: 900)]) == .blocked)
    #expect(decision([entry(.ruleBlocked, age: 900.001)]) == .noHistory)
    #expect(decision([entry(.ruleBlocked, age: 0)]) == .noHistory)
    #expect(decision([entry(.ruleBlocked, age: -1)]) == .noHistory)
    #expect(decision([]) == .noHistory)
  }

  @Test("Upstream blocks take precedence over permitted results but not incomplete evidence")
  func upstreamPrecedence() {
    #expect(decision([entry(.upstreamBlocked)]) == .upstreamBlocked)
    #expect(decision([entry(.upstreamBlocked), entry(.permitted, type: "AAAA")]) == .upstreamBlocked)
    #expect(decision([entry(.upstreamBlocked), entry(.inconclusive, type: "AAAA")]) == .unavailable)
    #expect(decision([entry(.upstreamBlocked), entry(.ruleBlocked, type: "AAAA")]) == .blocked)
  }

  private func decision(_ entries: [DomainQueryEntry], complete: Bool = true) -> DomainQueryDecision {
    BrowserDomainUnblockPolicy.evaluate(
      DomainQueryHistory(entries: entries, isComplete: complete),
      domain: "example.com",
      clientIP: clientIP,
      interval: interval)
  }

  private func entry(
    _ handling: DomainQueryHandling,
    age: TimeInterval = 10,
    type: String = "A",
    domain: String = "example.com",
    client: String = "192.168.1.50"
  ) -> DomainQueryEntry {
    DomainQueryEntry(
      domain: domain,
      timestamp: end.addingTimeInterval(-age),
      queryType: type,
      clientIP: client,
      handling: handling,
      status: String(describing: handling),
      reply: nil)
  }
}
