import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `URLSessionFactory` with per-call overrides and
/// call tracking. Without a handler, each call returns a fresh `MockURLSession`.
@MainActor
final class MockURLSessionFactory: URLSessionFactory {
  var makeSessionHandler: (@MainActor () -> any HTTPRequestable)?
  private(set) var makeSessionCallCount = 0
  private(set) var lastConfiguration: URLSessionConfiguration?
  private(set) var lastTrustedHosts: Set<String>?
  private(set) var trustedHostsHistory: [Set<String>] = []

  func makeSession(
    configuration: URLSessionConfiguration,
    trustedHosts: Set<String>
  ) -> any HTTPRequestable {
    makeSessionCallCount += 1
    lastConfiguration = configuration
    lastTrustedHosts = trustedHosts
    trustedHostsHistory.append(trustedHosts)
    if let makeSessionHandler {
      return makeSessionHandler()
    }
    return MockURLSession()
  }
}
