import Defaults
import Foundation
import Testing

@testable import HoleberryCore

@MainActor
@Suite("ExistingDomainUnblock")
struct ExistingDomainUnblockTests {
  private func parkingDecorator(
    raw: MockPiholeAPI, suite: UserDefaults
  ) -> TemporaryUnblockPiholeServiceDecorator {
    TemporaryUnblockPiholeServiceDecorator(
      service: raw, defaultsSuite: suite, retrySleep: { _ in },
      sleep: { _ in try await Task.sleep(for: .seconds(60)) })
  }

  @Test func absentEntryDoesNotAdd() async throws {
    let raw = MockPiholeAPI()
    let decorator = parkingDecorator(raw: raw, suite: TestDefaults.makeSuite())
    #expect(try await decorator.unblockExistingDomain("WWW.Example.com", duration: 60) == nil)
    #expect(raw.getDomainLastDomain == "www.example.com")
    #expect(raw.getDomainLastList == .allow)
    #expect(raw.addDomainCallCount == 0)
  }

  @Test(arguments: [true, false])
  func unrelatedEntryDoesNotAdd(enabled: Bool) async throws {
    let raw = MockPiholeAPI()
    raw.getDomainStub = .success(DomainEntry(id: 1, domain: "example.com", type: 0, comment: nil, enabled: enabled))
    let decorator = parkingDecorator(raw: raw, suite: TestDefaults.makeSuite())
    #expect(
      try await decorator.unblockExistingDomain("example.com", duration: 60) == .alreadyPresent(enabled: enabled))
    #expect(raw.addDomainCallCount == 0)
  }

  @Test(arguments: [ServerVersion.v5, .v6], [true, false])
  func ownedEntryRenewsOrPromotes(version: ServerVersion, permanent: Bool) async throws {
    let raw = MockPiholeAPI(version: version)
    let suite = TestDefaults.makeSuite()
    let decorator = parkingDecorator(raw: raw, suite: suite)
    _ = try await decorator.unblockDomain("example.com", duration: 120)
    let before = try #require(Defaults[.tempUnblocks(for: raw.id, suite: suite)].first)
    raw.getDomainStub = .success(
      DomainEntry(id: 1, domain: "example.com", type: 0, comment: version == .v5 ? nil : before.uuid))
    let result = try await decorator.unblockExistingDomain("example.com", duration: permanent ? nil : 300)
    #expect(result == (permanent ? .promoted : .renewed))
    #expect(raw.addDomainCallCount == 1, "Only initial setup may add")
    let records = Defaults[.tempUnblocks(for: raw.id, suite: suite)]
    if permanent {
      #expect(records.isEmpty)
    } else {
      #expect(records.first?.uuid == before.uuid)
      #expect(records.first?.durationSeconds == 300)
    }
    try await decorator.deleteDomain("example.com", from: .allow)
  }

  enum Ineligible: CaseIterable { case disabled, changedToken, expired, pendingRemoval }

  @Test(arguments: Ineligible.allCases)
  func staleOrChangedOwnershipCannotRenew(condition: Ineligible) async throws {
    let raw = MockPiholeAPI()
    let suite = TestDefaults.makeSuite()
    let record = TempUnblockRecord(
      domain: "example.com", uuid: "saved-token",
      startDateUTC: Date().addingTimeInterval(condition == .expired ? -1000 : 0), durationSeconds: 300,
      pendingRemoval: condition == .pendingRemoval)
    Defaults[.tempUnblocks(for: raw.id, suite: suite)] = [record]
    let entry = DomainEntry(
      id: 1, domain: "example.com", type: 0,
      comment: condition == .changedToken ? "via holeberryapp.com / replacement" : record.uuid,
      enabled: condition != .disabled)
    raw.getDomainStub = .success(entry)
    raw.getDomainsStub = .success([entry])
    let decorator = parkingDecorator(raw: raw, suite: suite)
    let result = try await decorator.unblockExistingDomain("example.com", duration: 600)
    #expect(result == .alreadyPresent(enabled: condition != .disabled))
    #expect(raw.addDomainCallCount == 0)
    #expect(Defaults[.tempUnblocks(for: raw.id, suite: suite)].first == record)
    try await decorator.deleteDomain("example.com", from: .allow)
  }

  @Test func errorsRemainFailuresAndNeverAdd() async {
    let raw = MockPiholeAPI()
    raw.getDomainStub = .failure(PiholeError.unauthorized)
    let decorator = parkingDecorator(raw: raw, suite: TestDefaults.makeSuite())
    await #expect(throws: PiholeError.unauthorized) {
      try await decorator.unblockExistingDomain("example.com", duration: nil)
    }
    #expect(raw.addDomainCallCount == 0)
  }

  @Test func separateWWWOperationPreservesApexTimer() async throws {
    let raw = MockPiholeAPI()
    let suite = TestDefaults.makeSuite()
    let decorator = parkingDecorator(raw: raw, suite: suite)
    _ = try await decorator.unblockDomain("example.com", duration: 300)
    let apex = try #require(Defaults[.tempUnblocks(for: raw.id, suite: suite)].first)
    #expect(try await decorator.unblockExistingDomain("www.example.com", duration: nil) == nil)
    #expect(Defaults[.tempUnblocks(for: raw.id, suite: suite)] == [apex])
    #expect(raw.addDomainCallCount == 1)
    try await decorator.deleteDomain("example.com", from: .allow)
  }
  @Test func expiryDeletionFinishesBeforeExistingOnlyRead() async throws {
    let raw = MockPiholeAPI()
    let suite = TestDefaults.makeSuite()
    var releaseExpiry: CheckedContinuation<Void, Never>?
    var finishDelete: CheckedContinuation<Void, Never>?
    var rowExists = true
    raw.getDomainHandler = { domain in
      rowExists ? DomainEntry(id: 1, domain: domain, type: 0, comment: raw.addDomainLastComment) : nil
    }
    raw.deleteDomainHandler = { _, _ in
      await withCheckedContinuation { finishDelete = $0 }
      rowExists = false
    }
    let decorator = TemporaryUnblockPiholeServiceDecorator(
      service: raw, defaultsSuite: suite, retrySleep: { _ in },
      sleep: { _ in await withCheckedContinuation { releaseExpiry = $0 } })
    _ = try await decorator.unblockDomain("example.com", duration: 0)
    await waitUntil { releaseExpiry != nil }
    releaseExpiry?.resume()
    releaseExpiry = nil
    await waitUntil { finishDelete != nil }
    let request = Task { try await decorator.unblockExistingDomain("example.com", duration: 300) }
    await settle()
    #expect(raw.getDomainCallCount == 1, "The read must wait for expiry's DELETE under the domain lock")
    finishDelete?.resume()
    finishDelete = nil
    #expect(try await request.value == nil)
    #expect(raw.getDomainCallCount == 2)
    #expect(raw.addDomainCallCount == 1, "The existing-only operation must not recreate the expired row")
    #expect(Defaults[.tempUnblocks(for: raw.id, suite: suite)].isEmpty)
  }

}
