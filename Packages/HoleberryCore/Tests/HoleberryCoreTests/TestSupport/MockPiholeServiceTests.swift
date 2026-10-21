import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("MockPiholeService")
struct MockPiholeServiceTests {
  @Test(arguments: [DomainUnblockOutcome.added, .renewed, .promoted, .alreadyPresent(enabled: false)])
  func explicitOutcome(outcome: DomainUnblockOutcome) async throws {
    let mock = MockPiholeService()
    mock.unblockDomainStub = .success(outcome)
    #expect(try await mock.unblockDomain("test.com", duration: 60) == outcome)
    #expect(mock.unblockDomainCallCount == 1)
    #expect(mock.unblockDomainLastDomain == "test.com")
    #expect(mock.unblockDomainLastDuration == 60)
    #expect(mock.addDomainCallCount == 0)
    #expect(mock.getDomainCallCount == 0)
  }

  @Test func handlerPrecedesStubAndTracksArguments() async throws {
    let mock = MockPiholeService()
    mock.unblockDomainStub = .failure(PiholeError.unauthorized)
    mock.unblockDomainHandler = { _, duration in duration == nil ? .promoted : .renewed }
    #expect(try await mock.unblockDomain("temporary.com", duration: 300) == .renewed)
    #expect(try await mock.unblockDomain("permanent.com", duration: nil) == .promoted)
    #expect(mock.unblockDomainArgs.map(\.domain) == ["temporary.com", "permanent.com"])
    #expect(mock.unblockDomainArgs.map(\.duration) == [300, nil])
    #expect(mock.unblockDomainLastDuration == nil)
  }

  @Test func failuresAreNotRetried() async {
    let mock = MockPiholeService()
    mock.unblockDomainStub = .failure(PiholeError.network("offline"))
    await #expect(throws: PiholeError.network("offline")) {
      try await mock.unblockDomain("test.com", duration: nil)
    }
    #expect(mock.unblockDomainCallCount == 1)
  }
}
