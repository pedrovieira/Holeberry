import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `URLSessionFactory`.
///
/// Records each requested configuration and trusted-host set, and returns an
/// injected transport so callers never build a real `URLSession` in tests.
@MainActor
final class MockURLSessionFactory: URLSessionFactory {
  var sessionBuilder: () -> (any HTTPRequestable) = { MockURLSession() }
  private(set) var makeSessionCallCount = 0
  private(set) var makeSessionLastTrustedHosts: Set<String>?
  private(set) var makeSessionTrustedHostsHistory: [Set<String>] = []
  private(set) var makeSessionConfigurations: [URLSessionConfiguration] = []
  private(set) var createdSessions: [any HTTPRequestable] = []

  var createdMockSessions: [MockURLSession] {
    createdSessions.compactMap { $0 as? MockURLSession }
  }

  func makeSession(
    configuration: URLSessionConfiguration,
    trustedHosts: Set<String>
  ) -> any HTTPRequestable {
    makeSessionCallCount += 1
    makeSessionLastTrustedHosts = trustedHosts
    makeSessionTrustedHostsHistory.append(trustedHosts)
    makeSessionConfigurations.append(configuration.copy() as! URLSessionConfiguration)
    let session = sessionBuilder()
    createdSessions.append(session)
    return session
  }
}
