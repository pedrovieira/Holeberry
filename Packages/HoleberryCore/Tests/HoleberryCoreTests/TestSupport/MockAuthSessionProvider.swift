import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `AuthSessionProviding` for unit tests.
final class MockAuthSessionProvider: AuthSessionProviding, @unchecked Sendable {
  /// Closure invoked by `authorizedRequest` to simulate the auth-wrapped call.
  /// Defaults to successfully returning the operation's result.
  var authorizedRequestStub: (@Sendable (String) async throws -> (Data, HTTPURLResponse))?

  /// If set, `login` throws this error; otherwise succeeds.
  var loginError: (any Error)?

  /// Tracks how many times `login` was called.
  private(set) var loginCallCount = 0

  /// Tracks how many times `logout` was called.
  private(set) var logoutCallCount = 0

  /// The SID passed to the operation closure.
  var stubbedSID = "mock-sid"

  /// Simulated password-less state reported to the service.
  var isPasswordless = false

  init() {}

  func authorizedRequest<T: Sendable>(
    _ operation: @Sendable (String) async throws -> (T, HTTPURLResponse)
  ) async throws -> T {
    if let stub = authorizedRequestStub {
      // When a stub is set, bypass the operation entirely.
      // The V6 service always uses T = (Data, HTTPURLResponse),
      // and the stub returns (Data, HTTPURLResponse) — a direct match.
      return try await stub(stubbedSID) as! T
    }
    let (result, _) = try await operation(stubbedSID)
    return result
  }

  func login() async throws {
    loginCallCount += 1
    if let loginError { throw loginError }
  }

  func logout() async {
    logoutCallCount += 1
  }
}
