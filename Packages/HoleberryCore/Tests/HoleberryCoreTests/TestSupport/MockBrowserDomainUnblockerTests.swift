import Testing

@testable import HoleberryCore

@MainActor
@Suite("Mock browser domain unblocker")
struct MockBrowserDomainUnblockerTests {
  @Test(arguments: [
    BrowserDomainUnblockOutcome.processed, .noHistory, .notBlocked, .upstreamBlocked, .unavailable,
    .noServers, .missingClientIP, .inProgress, .cancelled, .failed(.unauthorized)
  ])
  func returnsEachOutcome(outcome: BrowserDomainUnblockOutcome) async {
    let mock = MockBrowserDomainUnblocker()
    mock.unblockStub = BrowserDomainUnblockResult(outcome: outcome, requestedDomain: "example.com")
    #expect(await mock.unblock(domain: "example.com", duration: 60).outcome == outcome)
    #expect(mock.unblockCallCount == 1)
    #expect(mock.unblockLastDomain == "example.com")
    #expect(mock.unblockLastDuration == 60)
  }

  @Test func handlerOverridesStubAndPreservesNilDuration() async {
    let mock = MockBrowserDomainUnblocker()
    mock.unblockHandler = { domain, duration in
      BrowserDomainUnblockResult(outcome: duration == nil ? .processed : .notBlocked, requestedDomain: domain)
    }
    #expect(await mock.unblock(domain: "example.com", duration: 60).outcome == .notBlocked)
    #expect(await mock.unblock(domain: "www.example.com", duration: nil).outcome == .processed)
    #expect(mock.unblockCallCount == 2)
    #expect(mock.unblockArgs.map(\.domain) == ["example.com", "www.example.com"])
    #expect(mock.unblockArgs.map(\.duration) == [60, nil])
    #expect(mock.unblockLastDuration == nil)
  }
}
