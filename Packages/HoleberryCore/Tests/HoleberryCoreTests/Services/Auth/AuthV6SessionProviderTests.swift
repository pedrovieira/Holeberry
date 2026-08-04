import Foundation
import Testing

@testable import HoleberryCore

// MARK: - Helpers

/// Build a 200 auth response with the given SID.
private func makeAuthResponse(sid: String = "test-sid", totp: Bool = false) -> Data {
  let json = "{\"session\":{\"sid\":\"\(sid)\",\"csrf\":\"test-csrf\",\"validity\":3600},\"totp\":\(totp)}"
  return Data(json.utf8)
}

/// Build an HTTPURLResponse with the given status code.
private func makeHTTPResponse(statusCode: Int = 200) -> HTTPURLResponse? {
  guard let url = URL(string: "http://192.168.1.100/api/auth") else { return nil }
  return HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)
}

// MARK: - Tests

@Suite("AuthV6SessionProvider")
final class AuthV6SessionProviderTests {
  private let mockSession = MockURLSession()
  private let host = URL(string: "http://192.168.1.100")!

  private func makeSession(credential: String = "test-password") -> AuthV6SessionProvider {
    AuthV6SessionProvider(host: host, password: credential, urlSession: mockSession)
  }

  /// Operation that always succeeds with 200 and returns the SID.
  private nonisolated static let alwaysSucceed: @Sendable (String) async throws -> (String, HTTPURLResponse) = { sid in
    guard let response = makeHTTPResponse() else {
      throw PiholeError.unknown("Failed to create test response")
    }
    return (sid, response)
  }

  // MARK: - Happy path

  @Test("Logs in once and reuses SID")
  func happyPathLogsInOnceAndReusesSid() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/auth")
        guard let response = makeHTTPResponse() else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (makeAuthResponse(), response)
      }
    ]

    let session = makeSession()

    let result1 = try await session.authorizedRequest(Self.alwaysSucceed)
    #expect(result1 == "test-sid")
    #expect(mockSession.requests.count == 1, "Should have logged in exactly once")

    let result2 = try await session.authorizedRequest(Self.alwaysSucceed)
    #expect(result2 == "test-sid")
    #expect(mockSession.requests.count == 1, "Should NOT have logged in again — SID reused")
  }

  // MARK: - 401 handling

  @Test("401 mid-session triggers relogin and retry")
  func test401MidSessionTriggersReloginAndRetry() async throws {
    mockSession.handlers = [
      // Login
      { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/auth")
        guard let response = makeHTTPResponse() else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (makeAuthResponse(sid: "sid-1"), response)
      },
      // First API call — 401
      { _ in
        guard let response = makeHTTPResponse(statusCode: 401) else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (Data("Unauthorized".utf8), response)
      },
      // Re-login
      { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/auth")
        guard let response = makeHTTPResponse() else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (makeAuthResponse(sid: "sid-2"), response)
      },
      // Second API call — OK
      { _ in
        guard let response = makeHTTPResponse() else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (Data("OK".utf8), response)
      }
    ]

    let operation: @Sendable (String) async throws -> (String, HTTPURLResponse) = { [mockSession] _ in
      let request = URLRequest(url: URL(string: "http://192.168.1.100/api/test")!)
      let (data, response) = try await mockSession.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        throw PiholeError.unknown("Invalid response")
      }
      return (String(data: data, encoding: .utf8) ?? "", httpResponse)
    }

    let session = makeSession()
    let result = try await session.authorizedRequest(operation)

    #expect(mockSession.requests.count == 4, "Should have made 4 requests")
    #expect(result == "OK")
  }

  @Test("Persistent 401 after relogin throws reauthenticationFailed")
  func persistent401AfterReloginThrowsReauthenticationFailed() async throws {
    mockSession.handlers = [
      // Login
      { _ in
        guard let response = makeHTTPResponse() else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (makeAuthResponse(), response)
      },
      // API call — 401 (triggers relogin)
      { _ in
        guard let response = makeHTTPResponse(statusCode: 401) else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (Data("Unauthorized".utf8), response)
      },
      // Re-login
      { _ in
        guard let response = makeHTTPResponse() else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (makeAuthResponse(), response)
      },
      // Retry — 401 again
      { _ in
        guard let response = makeHTTPResponse(statusCode: 401) else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (Data("Unauthorized".utf8), response)
      }
    ]

    let session = makeSession()

    let operation: @Sendable (String) async throws -> (String, HTTPURLResponse) = { [mockSession] _ in
      let request = URLRequest(url: URL(string: "http://192.168.1.100/api/test")!)
      let (data, response) = try await mockSession.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        throw PiholeError.unknown("Invalid response")
      }
      return (String(data: data, encoding: .utf8) ?? "", httpResponse)
    }

    await #expect(throws: PiholeError.reauthenticationFailed) {
      try await session.authorizedRequest(operation)
    }
  }

  // MARK: - Invalid credentials

  @Test("Invalid credentials throw")
  func invalidCredentialsThrows() async throws {
    mockSession.handlers = [
      { _ in
        guard let response = makeHTTPResponse(statusCode: 401) else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (Data(), response)
      }
    ]

    let session = makeSession()
    await #expect(throws: PiholeError.invalidCredentials) {
      try await session.authorizedRequest(Self.alwaysSucceed)
    }
  }

  // MARK: - Rate limiting

  @Test("Rate limited throws")
  func rateLimitedThrows() async throws {
    mockSession.handlers = [
      { _ in
        guard let response = makeHTTPResponse(statusCode: 429) else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (Data(), response)
      }
    ]

    let session = makeSession()
    await #expect(throws: PiholeError.rateLimited) {
      try await session.authorizedRequest(Self.alwaysSucceed)
    }
  }

  // MARK: - Logout

  @Test("Logout clears session")
  func logoutClearsSession() async throws {
    mockSession.handlers = [
      // Login
      { _ in
        guard let response = makeHTTPResponse() else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (makeAuthResponse(), response)
      },
      // Logout (DELETE /api/auth)
      { request in
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/auth")
        guard let response = makeHTTPResponse(statusCode: 204) else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (Data(), response)
      },
      // Login again after logout
      { _ in
        guard let response = makeHTTPResponse() else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (makeAuthResponse(), response)
      }
    ]

    let session = makeSession()

    _ = try await session.authorizedRequest(Self.alwaysSucceed)
    #expect(mockSession.requests.count == 1)

    await session.logout()

    _ = try await session.authorizedRequest(Self.alwaysSucceed)
    #expect(mockSession.requests.count == 3, "Should re-authenticate after logout")
  }

  // MARK: - Explicit login

  @Test("Explicit login")
  func explicitLogin() async throws {
    mockSession.handlers = [
      { _ in
        guard let response = makeHTTPResponse() else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (makeAuthResponse(), response)
      }
    ]

    let session = makeSession()
    try await session.login()

    let result = try await session.authorizedRequest(Self.alwaysSucceed)
    #expect(result == "test-sid")
  }

  // MARK: - Non-401 propagation

  @Test("Non-401 status codes propagate without triggering relogin", arguments: [403, 404, 418, 429, 500, 502])
  func non401StatusCodesPropagateWithoutRelogin(statusCode: Int) async throws {
    mockSession.handlers = [
      { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/auth")
        guard let response = makeHTTPResponse() else {
          throw PiholeError.unknown("Failed to create test response")
        }
        return (makeAuthResponse(), response)
      },
      { _ in
        guard let response = makeHTTPResponse(statusCode: statusCode) else {
          throw PiholeError.unknown("Failed to create test response")
        }
        return (Data("body-\(statusCode)".utf8), response)
      }
    ]

    let session = makeSession()

    let result = try await session.authorizedRequest { [mockSession] _ in
      let request = URLRequest(url: URL(string: "http://192.168.1.100/api/test")!)
      let (data, response) = try await mockSession.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        throw PiholeError.unknown("Invalid response")
      }
      return (String(data: data, encoding: .utf8) ?? "", httpResponse)
    }

    #expect(result == "body-\(statusCode)")
    #expect(mockSession.requests.count == 2, "Should have made exactly 2 requests: login + operation, with no retry")
  }

  // MARK: - 2xx propagation

  @Test("2xx status codes propagate without triggering relogin", arguments: [200, 201, 204])
  func successStatusCodesPropagateWithoutRelogin(statusCode: Int) async throws {
    mockSession.handlers = [
      { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/auth")
        guard let response = makeHTTPResponse() else {
          throw PiholeError.unknown("Failed to create test response")
        }
        return (makeAuthResponse(), response)
      },
      { _ in
        guard let response = makeHTTPResponse(statusCode: statusCode) else {
          throw PiholeError.unknown("Failed to create test response")
        }
        return (Data("body-\(statusCode)".utf8), response)
      }
    ]

    let session = makeSession()

    let result = try await session.authorizedRequest { [mockSession] _ in
      let request = URLRequest(url: URL(string: "http://192.168.1.100/api/test")!)
      let (data, response) = try await mockSession.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        throw PiholeError.unknown("Invalid response")
      }
      return (String(data: data, encoding: .utf8) ?? "", httpResponse)
    }

    #expect(result == "body-\(statusCode)")
    #expect(mockSession.requests.count == 2, "Should have made exactly 2 requests: login + operation, with no retry")
  }

  // MARK: - TOTP handling

  @Test("TOTP required propagates immediately from authorizedRequest")
  func totpRequiredPropagatesImmediately() async throws {
    mockSession.handlers = [
      { _ in
        guard let response = makeHTTPResponse() else {
          throw PiholeError.unknown("Failed to create test response")
        }
        return (makeAuthResponse(totp: true), response)
      }
    ]

    let session = makeSession()

    await #expect(throws: PiholeError.totpRequired) {
      try await session.authorizedRequest(Self.alwaysSucceed)
    }

    #expect(mockSession.requests.count == 1, "Should have only made the login request")
  }

  // MARK: - Concurrency

  @Test("Concurrent authorizedRequest calls coalesce into one login")
  func concurrentLoginCoalescing() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.path == "/api/auth")
        #expect(request.httpMethod == "POST")
        guard let response = makeHTTPResponse() else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (makeAuthResponse(), response)
      }
    ]

    let session = makeSession()

    async let first = session.authorizedRequest(Self.alwaysSucceed)
    async let second = session.authorizedRequest(Self.alwaysSucceed)
    let (a, b) = try await (first, second)

    #expect(a == "test-sid")
    #expect(b == "test-sid")
    #expect(mockSession.requests.count == 1, "Both callers should share a single login request")
  }
}
