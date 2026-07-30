import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `AuthSessionFactory` for unit tests.
final class MockAuthSessionFactory: AuthSessionFactory, @unchecked Sendable {
  /// If set, `makeSession` returns this provider; otherwise throws the error.
  var stubbedProvider: AuthSessionProviding?
  /// Error thrown by `makeSession`.
  var stubbedError: Error?

  func makeSession(
    host: URL,
    password: String,
    urlSession: any HTTPRequestable,
    piHoleVersion: ServerVersion
  ) throws -> AuthSessionProviding {
    if let stubbedError { throw stubbedError }
    return stubbedProvider ?? MockAuthSessionProvider()
  }
}
