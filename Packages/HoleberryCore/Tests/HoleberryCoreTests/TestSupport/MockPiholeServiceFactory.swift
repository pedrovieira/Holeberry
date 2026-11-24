import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `PiholeServiceFactory` with stub injection and
/// call-count tracking. Without an explicit stub, `buildService` returns a fresh
/// `MockPiholeService` for the requested config.
@MainActor
final class MockPiholeServiceFactory: PiholeServiceFactory {
  var buildServiceStub: (any PiholeServiceProviding)?
  /// Optional per-config handler; takes precedence over `buildServiceStub`.
  var buildServiceHandler: ((ServerConfig) -> (any PiholeServiceProviding))?
  var buildServiceError: (any Error)?
  /// Per-configuration build failures take precedence over `buildServiceError`.
  var buildServiceErrorsByConfig: [UUID: any Error] = [:]
  private(set) var buildServiceCallCount = 0
  private(set) var buildServiceLastConfig: ServerConfig?
  private(set) var buildServiceLastCredential: String?
  private(set) var buildServiceLastSession: (any HTTPRequestable)?

  func buildService(
    config: ServerConfig,
    credential: String,
    session: any HTTPRequestable
  ) throws -> any PiholeServiceProviding {
    buildServiceCallCount += 1
    buildServiceLastConfig = config
    buildServiceLastCredential = credential
    buildServiceLastSession = session
    if let error = buildServiceErrorsByConfig[config.id] {
      throw error
    }
    if let buildServiceError {
      throw buildServiceError
    }
    if let buildServiceHandler {
      return buildServiceHandler(config)
    }
    if let buildServiceStub {
      return buildServiceStub
    }
    return MockPiholeService(id: config.id, url: config.url, version: config.version)
  }
}
