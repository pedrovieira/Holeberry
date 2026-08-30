import Foundation
import Testing

@testable import HoleberryCore

/// Meta-tests verifying that `MockPiholeService` — the test double used across the
/// test suite — correctly stubs return values, tracks call counts, captures
/// parameters, and propagates injected failures. If these pass, a failure in
/// another test that uses the mock is a real bug, not a broken mock.
@Suite("MockPiholeService")
@MainActor
struct MockPiholeServiceTests {
  @Test func checkStatus() async throws {
    let mock = MockPiholeService()
    mock.checkStatusStub = .success(.disabled(remainingSeconds: 30))
    let status = try await mock.checkStatus()
    #expect(status == .disabled(remainingSeconds: 30))
    #expect(mock.checkStatusCallCount == 1)
  }

  @Test func setBlocking() async throws {
    let mock = MockPiholeService()
    try await mock.setBlocking(enabled: false, duration: 300)
    #expect(mock.setBlockingCallCount == 1)
    #expect(mock.setBlockingLastEnabled == false)
    #expect(mock.setBlockingLastDuration == 300)
  }

  @Test func addDomain() async throws {
    let mock = MockPiholeService()
    let expected = DomainEntry(id: 99, domain: "test.com", type: 0, comment: "test-uuid")
    mock.addDomainStub = .success(expected)
    let result = try await mock.addDomain("test.com", to: .allow, comment: "test-uuid")
    #expect(result == expected)
    #expect(mock.addDomainCallCount == 1)
    #expect(mock.addDomainLastDomain == "test.com")
    #expect(mock.addDomainLastList == .allow)
    #expect(mock.addDomainLastComment == "test-uuid")
  }

  @Test func failureInjection() async {
    let mock = MockPiholeService()
    mock.checkStatusStub = .failure(PiholeError.unauthorized)
    await #expect(throws: PiholeError.unauthorized) {
      try await mock.checkStatus()
    }
  }

  @Test func deleteDomainByName() async throws {
    let mock = MockPiholeService()
    try await mock.deleteDomain(domain: "test.com")
    #expect(mock.deleteDomainByNameCallCount == 1)
  }

  @Test func updateGravity() async throws {
    let mock = MockPiholeService()
    try await mock.updateGravity()
    #expect(mock.updateGravityCallCount == 1)

    mock.updateGravityStub = .failure(PiholeError.network("down"))
    await #expect(throws: PiholeError.network("down")) {
      try await mock.updateGravity()
    }
  }
}
