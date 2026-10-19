import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("Disabled temporary unblock entries")
struct TempUnblockDisabledEntryTests {
  @Test(
    "Disabled owned entries neither renew nor promote",
    arguments: [TimeInterval?.none, .some(3600)], [ServerVersion.v5, .v6])
  func disabledOwnedEntry(duration: TimeInterval?, version: ServerVersion) async throws {
    let mock = MockPiholeService(version: version)
    let suite = TestDefaults.makeSuite()
    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: mock, defaultsSuite: suite, retrySleep: { _ in },
      sleep: {
        _ in
        try await Task.sleep(for: .seconds(60))
      })
    _ = try await decorator.unblockDomain("x.com", duration: 300)
    let original = try #require(Defaults[.tempUnblocks(for: mock.id, suite: suite)].first)
    mock.addDomainStub = .success(.alreadyPresent)
    mock.getDomainStub = .success(
      DomainEntry(id: 1, domain: "x.com", type: 0, comment: original.uuid, enabled: false))

    let outcome = try await decorator.unblockDomain("x.com", duration: duration)

    #expect(outcome == .alreadyPresent(enabled: false))
    let remaining = try #require(Defaults[.tempUnblocks(for: mock.id, suite: suite)].first)
    #expect(remaining.uuid == original.uuid)
    #expect(remaining.startDateUTC == original.startDateUTC)
    #expect(remaining.durationSeconds == 300)
    try await decorator.deleteDomain("x.com", from: .allow)
  }

  @Test("Disabled matching-token entries are not recovered as successes", arguments: [false, true])
  func disabledRecovery(addThrows: Bool) async throws {
    let mock = MockPiholeService()
    let suite = TestDefaults.makeSuite()
    mock.addDomainStub = addThrows ? .failure(URLError(.timedOut)) : .success(.alreadyPresent)
    mock.getDomainHandler = { [weak mock] domain in
      DomainEntry(id: 1, domain: domain, type: 0, comment: mock?.addDomainLastComment, enabled: false)
    }
    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: mock, defaultsSuite: suite, retrySleep: { _ in },
      sleep: {
        _ in
        try await Task.sleep(for: .seconds(60))
      })

    let outcome = try await decorator.unblockDomain("x.com", duration: 300)

    #expect(outcome == .alreadyPresent(enabled: false))
    #expect(mock.addDomainCallCount == 1)
    #expect(mock.getDomainCallCount == 1)
    #expect(mock.addDomainLastComment?.hasPrefix("via holeberryapp.com / ") == true)
    #expect(Defaults[.tempUnblocks(for: mock.id, suite: suite)].isEmpty)
    try await decorator.deleteDomain("x.com", from: .allow)
  }
}
