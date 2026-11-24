import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `OnDemandSessionProviding`.
///
/// Records each requested trusted-host set and returns an injected session, so
/// on-demand client tests never build a real `URLSession`.
@MainActor
final class MockOnDemandSessionProvider: OnDemandSessionProviding {
  /// Produces one transport per request. Defaults to a fresh `MockURLSession`.
  var sessionFactory: () -> (any HTTPRequestable) = { MockURLSession() }
  private(set) var makeSessionCallCount = 0
  private(set) var makeSessionLastTrustedHosts: Set<String>?
  private(set) var makeSessionTrustedHostsHistory: [Set<String>] = []
  private(set) var createdSessions: [any HTTPRequestable] = []

  var createdMockSessions: [MockURLSession] {
    createdSessions.compactMap { $0 as? MockURLSession }
  }

  func makeSession(trustedHosts: Set<String>) -> any HTTPRequestable {
    makeSessionCallCount += 1
    makeSessionLastTrustedHosts = trustedHosts
    makeSessionTrustedHostsHistory.append(trustedHosts)
    let session = sessionFactory()
    createdSessions.append(session)
    return session
  }
}
