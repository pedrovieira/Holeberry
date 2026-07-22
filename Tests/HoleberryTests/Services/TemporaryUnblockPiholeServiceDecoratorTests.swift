import Defaults
import Foundation
import Testing

@testable import Holeberry

// swiftlint:disable type_name

@MainActor
@Suite("TemporaryUnblockPiholeServiceDecorator")
struct TemporaryUnblockPiholeServiceDecoratorTests {
  init() {
    // Clear persisted records
    Defaults[.tempUnblocks(for: UUID())] = []
  }

  // MARK: - unblockDomain (temporary)

  @Test("Temporary unblock adds tracking comment")
  func unblockDomainAddsTrackingComment() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(
      DomainEntry(id: 42, domain: "doubleclick.net", type: 0, comment: "via holeberryapp.com / test-uuid")
    )
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: mock)

    try await decorator.unblockDomain("doubleclick.net", duration: 300)

    #expect(mock.addDomainCallCount == 1, "Should call addDomain on wrapped service")
    #expect(mock.addDomainLastDomain == "doubleclick.net")
    #expect(mock.addDomainLastList == .allow)
    #expect(
      mock.addDomainLastComment?.hasPrefix("via holeberryapp.com / ") ?? false,
      "Comment should have holeberryapp prefix"
    )
  }

  // MARK: - unblockDomain (permanent)

  @Test("Permanent unblock has standard comment")
  func unblockDomainPermanentNoTracking() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(
      DomainEntry(id: 1, domain: "permanent.com", type: 0, comment: nil)
    )
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: mock)

    try await decorator.unblockDomain("permanent.com", duration: nil)

    #expect(mock.addDomainCallCount == 1)
    #expect(mock.addDomainLastComment == "via holeberryapp.com", "Permanent unblock should have standard comment")
  }

  // MARK: - Auto-expiry

  @Test("Auto-expiry removes record")
  func autoExpiryRemovesRecord() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(
      DomainEntry(id: 42, domain: "test.com", type: 0, comment: "via holeberryapp.com / uuid-1")
    )
    mock.deleteDomainByNameStub = .success(())

    let decorator = TemporaryUnblockPiholeServiceDecorator(service: mock)
    // Let init reconciliation finish
    try await Task.sleep(for: .milliseconds(100))
    try await decorator.unblockDomain("test.com", duration: 0.5)

    // Wait for expiry
    try await Task.sleep(for: .seconds(3))
    #expect(mock.deleteDomainByNameCallCount == 1, "Should delete domain after expiry")
  }

  @Test("Auto-expiry failure marks pending")
  func autoExpiryFailureMarksPending() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(
      DomainEntry(id: 42, domain: "test.com", type: 0, comment: "via holeberryapp.com / uuid-1")
    )
    mock.deleteDomainByNameStub = .failure(PiholeError.server(500, "Overloaded"))

    let decorator = TemporaryUnblockPiholeServiceDecorator(service: mock)
    // Let init reconciliation finish
    try await Task.sleep(for: .milliseconds(100))
    try await decorator.unblockDomain("test.com", duration: 0.5)

    try await Task.sleep(for: .seconds(3))
    #expect(mock.deleteDomainByNameCallCount == 1)
  }

  // MARK: - Passthrough

  @Test("addDomain passes through")
  func addDomainPassesThrough() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(
      DomainEntry(id: 1, domain: "passthrough.com", type: 0, comment: nil)
    )
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: mock)

    _ = try await decorator.addDomain("passthrough.com", to: .allow)

    #expect(mock.addDomainCallCount == 1)
    #expect(mock.addDomainLastComment == nil)
  }

  @Test("deleteDomain passes through")
  func deleteDomainPassesThrough() async throws {
    let mock = MockPiholeService()
    mock.deleteDomainByNameStub = .success(())
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: mock)

    try await decorator.deleteDomain(domain: "test.com")

    #expect(mock.deleteDomainByNameCallCount == 1)
  }

  @Test("checkStatus passes through")
  func checkStatusPassesThrough() async throws {
    let mock = MockPiholeService()
    mock.checkStatusStub = .success(.enabled)
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: mock)

    let status = try await decorator.checkStatus()

    #expect(mock.checkStatusCallCount == 1)
    #expect(status == .enabled)
  }
}
