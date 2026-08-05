import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `PiholeServiceFactory` with stub injection and
/// call-count tracking. Without an explicit stub, `buildService` returns a fresh
/// `MockPiholeService` for the requested config.
@MainActor
final class MockPiholeServiceFactory: PiholeServiceFactory {
  var buildServiceStub: (any PiholeServiceCommentAdding)?
  var buildServiceError: (any Error)?
  private(set) var buildServiceCallCount = 0
  private(set) var buildServiceLastConfig: ServerConfig?

  func buildService(
    config: ServerConfig,
    credential: String,
    session: any HTTPRequestable,
    suite: UserDefaults
  ) throws -> any PiholeServiceCommentAdding {
    buildServiceCallCount += 1
    buildServiceLastConfig = config
    if let buildServiceError {
      throw buildServiceError
    }
    if let buildServiceStub {
      return buildServiceStub
    }
    return MockPiholeService(id: config.id, url: config.url, version: config.version)
  }
}
