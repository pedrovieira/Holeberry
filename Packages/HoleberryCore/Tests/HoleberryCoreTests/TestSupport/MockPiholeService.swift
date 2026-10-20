import Foundation

@testable import HoleberryCore

/// Managed operation stubs are explicit; raw operations retain their independent stubs.
@MainActor
final class MockPiholeService: MockPiholeAPI, PiholeServiceProviding {
  var unblockDomainStub: Result<DomainUnblockOutcome, any Error> = .success(.added)
  var unblockDomainHandler: ((String, TimeInterval?) async throws -> DomainUnblockOutcome)?
  private(set) var unblockDomainCallCount = 0
  private(set) var unblockDomainLastDomain: String?
  private(set) var unblockDomainLastDuration: TimeInterval?
  private(set) var unblockDomainArgs: [(domain: String, duration: TimeInterval?)] = []

  @discardableResult
  func unblockDomain(_ domain: String, duration: TimeInterval?) async throws -> DomainUnblockOutcome {
    unblockDomainCallCount += 1
    unblockDomainLastDomain = domain
    unblockDomainLastDuration = duration
    unblockDomainArgs.append((domain, duration))
    if let unblockDomainHandler { return try await unblockDomainHandler(domain, duration) }
    return try unblockDomainStub.get()
  }
}
