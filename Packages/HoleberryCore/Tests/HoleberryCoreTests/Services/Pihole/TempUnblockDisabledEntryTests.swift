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
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: mock, defaultsSuite: suite) { _ in
      try await Task.sleep(for: .seconds(60))
    }
    _ = try await decorator.unblockDomain("x.com", duration: 300, ownershipID: UUID())
    let original = try #require(Defaults[.tempUnblocks(for: mock.id, suite: suite)].first)
    mock.addDomainStub = .success(.alreadyPresent)
    mock.getDomainStub = .success(
      DomainEntry(id: 1, domain: "x.com", type: 0, comment: original.uuid, enabled: false))

    let outcome = try await decorator.unblockDomain("x.com", duration: duration, ownershipID: UUID())

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
    let ownership = UUID()
    mock.addDomainStub = addThrows ? .failure(URLError(.timedOut)) : .success(.alreadyPresent)
    mock.getDomainStub = .success(
      DomainEntry(
        id: 1, domain: "x.com", type: 0,
        comment: "via holeberryapp.com / \(ownership.uuidString)", enabled: false))
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: mock, defaultsSuite: suite) { _ in
      try await Task.sleep(for: .seconds(60))
    }

    let outcome = try await decorator.unblockDomain("x.com", duration: 300, ownershipID: ownership)

    #expect(outcome == .alreadyPresent(enabled: false))
    #expect(Defaults[.tempUnblocks(for: mock.id, suite: suite)].isEmpty)
    try await decorator.deleteDomain("x.com", from: .allow)
  }
}
