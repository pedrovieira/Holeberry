import Defaults
import XCTest

@testable import Holeberry

@MainActor
final class TemporaryUnblockPiholeServiceDecoratorTests: XCTestCase {  // swiftlint:disable:this type_name
  override func setUp() {
    super.setUp()
    // Clear persisted records
    Defaults[.tempUnblocks(for: UUID())] = []
  }

  // MARK: - unblockDomain (temporary)

  func testUnblockDomainAddsTrackingComment() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(
      DomainEntry(id: 42, domain: "doubleclick.net", type: 0, comment: "via holeberryapp.com / test-uuid")
    )
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: mock)

    try await decorator.unblockDomain("doubleclick.net", duration: 300)

    XCTAssertEqual(mock.addDomainCallCount, 1, "Should call addDomain on wrapped service")
    XCTAssertEqual(mock.addDomainLastDomain, "doubleclick.net")
    XCTAssertEqual(mock.addDomainLastList, .allow)
    XCTAssertTrue(
      mock.addDomainLastComment?.hasPrefix("via holeberryapp.com / ") ?? false,
      "Comment should have holeberryapp prefix"
    )
  }

  // MARK: - unblockDomain (permanent)

  func testUnblockDomainPermanentNoTracking() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(
      DomainEntry(id: 1, domain: "permanent.com", type: 0, comment: nil)
    )
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: mock)

    try await decorator.unblockDomain("permanent.com", duration: nil)

    XCTAssertEqual(mock.addDomainCallCount, 1)
    XCTAssertEqual(mock.addDomainLastComment, "via holeberryapp.com", "Permanent unblock should have standard comment")
  }

  // MARK: - Auto-expiry

  func testAutoExpiryRemovesRecord() async throws {
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
    XCTAssertEqual(mock.deleteDomainByNameCallCount, 1, "Should delete domain after expiry")
  }

  func testAutoExpiryFailureMarksPending() async throws {
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
    XCTAssertEqual(mock.deleteDomainByNameCallCount, 1)
  }

  // MARK: - Passthrough

  func testAddDomainPassesThrough() async throws {
    let mock = MockPiholeService()
    mock.addDomainStub = .success(
      DomainEntry(id: 1, domain: "passthrough.com", type: 0, comment: nil)
    )
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: mock)

    _ = try await decorator.addDomain("passthrough.com", to: .allow)

    XCTAssertEqual(mock.addDomainCallCount, 1)
    XCTAssertEqual(mock.addDomainLastComment, nil)
  }

  func testDeleteDomainPassesThrough() async throws {
    let mock = MockPiholeService()
    mock.deleteDomainByNameStub = .success(())
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: mock)

    try await decorator.deleteDomain(domain: "test.com")

    XCTAssertEqual(mock.deleteDomainByNameCallCount, 1)
  }

  func testCheckStatusPassesThrough() async throws {
    let mock = MockPiholeService()
    mock.checkStatusStub = .success(.enabled)
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: mock)

    let status = try await decorator.checkStatus()

    XCTAssertEqual(mock.checkStatusCallCount, 1)
    XCTAssertEqual(status, .enabled)
  }
}
