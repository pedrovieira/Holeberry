import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `PiholeVersionDetecting` with stub injection and
/// call-count tracking.
final class MockPiholeVersionDetector: PiholeVersionDetecting, @unchecked Sendable {
  var detectStub: Result<ServerVersion, any Error> = .success(.v6)
  private(set) var detectCallCount = 0
  private(set) var detectLastBaseURL: URL?
  private(set) var detectLastSession: (any HTTPRequestable)?

  func detect(baseURL: URL, session: any HTTPRequestable) async throws -> ServerVersion {
    detectCallCount += 1
    detectLastBaseURL = baseURL
    detectLastSession = session
    return try detectStub.get()
  }
}
