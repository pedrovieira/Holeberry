import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `AuthSessionFactory` for unit tests.
final class MockAuthSessionFactory: AuthSessionFactory, @unchecked Sendable {
  /// If set, `makeSession` returns this provider; otherwise throws the error.
  var stubbedProvider: (any AuthSessionProviding)?
  /// Error thrown by `makeSession`.
  var stubbedError: (any Error)?

  func makeSession(
    host: URL,
    password: String,
    urlSession: any HTTPRequestable,
    piHoleVersion: ServerVersion
  ) throws -> any AuthSessionProviding {
    if let stubbedError { throw stubbedError }
    return stubbedProvider ?? MockAuthSessionProvider()
  }
}
