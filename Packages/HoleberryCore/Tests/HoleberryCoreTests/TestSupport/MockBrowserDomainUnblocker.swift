import Foundation

@testable import HoleberryCore

@MainActor
final class MockBrowserDomainUnblocker: BrowserDomainUnblocking {
  var unblockStub = BrowserDomainUnblockResult(outcome: .processed, requestedDomain: "example.com")
  var unblockHandler: ((String, TimeInterval?) async -> BrowserDomainUnblockResult)?
  private(set) var unblockCallCount = 0
  private(set) var unblockLastDomain: String?
  private(set) var unblockLastDuration: TimeInterval?
  private(set) var unblockArgs: [(domain: String, duration: TimeInterval?)] = []

  func unblock(domain: String, duration: TimeInterval?) async -> BrowserDomainUnblockResult {
    unblockCallCount += 1
    unblockLastDomain = domain
    unblockLastDuration = duration
    unblockArgs.append((domain, duration))
    if let unblockHandler { return await unblockHandler(domain, duration) }
    return unblockStub
  }
}
