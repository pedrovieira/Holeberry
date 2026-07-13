import Foundation
import XCTest

@testable import Holeberry

// MARK: - Mock URLProtocol

// swiftlint:disable static_over_final_class
private final class MockURLProtocol: URLProtocol {
  nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      XCTFail("No requestHandler set")
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if let data {
        client?.urlProtocol(self, didLoad: data)
      }
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
// swiftlint:enable static_over_final_class

// MARK: - Helpers

/// Build a 200 auth response with the given SID.
private func makeAuthResponse(sid: String = "test-sid") -> Data {
  let json = "{\"session\":{\"sid\":\"\(sid)\",\"csrf\":\"test-csrf\",\"validity\":3600},\"totp\":false}"
  return Data(json.utf8)
}

/// Build an HTTPURLResponse with the given status code.
private func makeHTTPResponse(statusCode: Int = 200) -> HTTPURLResponse? {
  guard let url = URL(string: "http://192.168.1.100/api/auth") else { return nil }
  return HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)
}

// MARK: - Tests

final class AuthV6SessionProviderTests: XCTestCase {
  // swiftlint:disable:next implicitly_unwrapped_optional
  private var urlSession: URLSession!
  private let host = URL(string: "http://192.168.1.100")!

  override func setUp() {
    super.setUp()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    urlSession = URLSession(configuration: config)
  }

  override func tearDown() {
    MockURLProtocol.requestHandler = nil
    urlSession = nil
    super.tearDown()
  }

  // MARK: - Init

  private func makeSession(credential: String = "test-password") -> AuthV6SessionProvider {
    AuthV6SessionProvider(host: host, password: credential, urlSession: urlSession)
  }

  /// Operation that always succeeds with 200 and returns the SID.
  private let alwaysSucceed: @Sendable (String) async throws -> (String, HTTPURLResponse) = { sid in
    guard let response = makeHTTPResponse() else {
      throw PiholeError.unknown("Failed to create test response")
    }
    return (sid, response)
  }

  // MARK: - Happy path

  func testHappyPathLogsInOnceAndReusesSid() async throws {
    var loginCount = 0
    MockURLProtocol.requestHandler = { _ in
      loginCount += 1
      guard let response = makeHTTPResponse() else {
        throw PiholeError.unknown("Failed to create response")
      }
      return (response, makeAuthResponse())
    }

    let session = makeSession()

    let result1 = try await session.authorizedRequest(alwaysSucceed)
    XCTAssertEqual(result1, "test-sid")
    XCTAssertEqual(loginCount, 1, "Should have logged in exactly once")

    let result2 = try await session.authorizedRequest(alwaysSucceed)
    XCTAssertEqual(result2, "test-sid")
    XCTAssertEqual(loginCount, 1, "Should NOT have logged in again — SID reused")
  }

  // MARK: - 401 handling

  func test401MidSessionTriggersReloginAndRetry() async throws {
    var loginCount = 0
    var firstApiCall = true

    MockURLProtocol.requestHandler = { request in
      if request.httpMethod == "POST", request.url?.path == "/api/auth" {
        loginCount += 1
        guard let response = makeHTTPResponse() else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (response, makeAuthResponse(sid: "sid-\(loginCount)"))
      }

      if firstApiCall {
        firstApiCall = false
        guard let response = makeHTTPResponse(statusCode: 401) else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (response, Data("Unauthorized".utf8))
      }

      guard let response = makeHTTPResponse() else {
        throw PiholeError.unknown("Failed to create response")
      }
      return (response, Data("OK".utf8))
    }

    let operation: @Sendable (String) async throws -> (String, HTTPURLResponse) = { _ in
      let request = URLRequest(url: URL(string: "http://192.168.1.100/api/test")!)
      let (data, response) = try await self.urlSession.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        throw PiholeError.unknown("Invalid response")
      }
      return (String(data: data, encoding: .utf8) ?? "", httpResponse)
    }

    let session = makeSession()
    let result = try await session.authorizedRequest(operation)

    XCTAssertEqual(loginCount, 2, "Should have logged in twice: initial + re-auth")
    XCTAssertEqual(result, "OK")
  }

  func testPersistent401AfterReloginThrowsReauthenticationFailed() async throws {
    MockURLProtocol.requestHandler = { request in
      if request.httpMethod == "POST", request.url?.path == "/api/auth" {
        guard let response = makeHTTPResponse() else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (response, makeAuthResponse())
      }
      guard let response = makeHTTPResponse(statusCode: 401) else {
        throw PiholeError.unknown("Failed to create response")
      }
      return (response, Data("Unauthorized".utf8))
    }

    let session = makeSession()
    await assertThrowsError(try await session.authorizedRequest(alwaysSucceed)) { error in
      XCTAssertEqual(error as? PiholeError, .reauthenticationFailed)
    }
  }

  // MARK: - Invalid credentials

  func testInvalidCredentialsThrows() async throws {
    MockURLProtocol.requestHandler = { _ in
      guard let response = makeHTTPResponse(statusCode: 401) else {
        throw PiholeError.unknown("Failed to create response")
      }
      return (response, Data())
    }

    let session = makeSession()
    await assertThrowsError(try await session.authorizedRequest(alwaysSucceed)) { error in
      XCTAssertEqual(error as? PiholeError, .invalidCredentials)
    }
  }

  // MARK: - Rate limiting

  func testRateLimitedThrows() async throws {
    MockURLProtocol.requestHandler = { _ in
      guard let response = makeHTTPResponse(statusCode: 429) else {
        throw PiholeError.unknown("Failed to create response")
      }
      return (response, Data())
    }

    let session = makeSession()
    await assertThrowsError(try await session.authorizedRequest(alwaysSucceed)) { error in
      XCTAssertEqual(error as? PiholeError, .rateLimited)
    }
  }

  // MARK: - Logout

  func testLogoutClearsSession() async throws {
    var loginCount = 0
    MockURLProtocol.requestHandler = { request in
      if request.httpMethod == "DELETE", request.url?.path == "/api/auth" {
        guard let response = makeHTTPResponse(statusCode: 204) else {
          throw PiholeError.unknown("Failed to create response")
        }
        return (response, nil)
      }
      loginCount += 1
      guard let response = makeHTTPResponse() else {
        throw PiholeError.unknown("Failed to create response")
      }
      return (response, makeAuthResponse())
    }

    let session = makeSession()

    _ = try await session.authorizedRequest(alwaysSucceed)
    XCTAssertEqual(loginCount, 1)

    await session.logout()

    _ = try await session.authorizedRequest(alwaysSucceed)
    XCTAssertEqual(loginCount, 2, "Should re-authenticate after logout")
  }

  // MARK: - Explicit login

  func testExplicitLogin() async throws {
    MockURLProtocol.requestHandler = { _ in
      guard let response = makeHTTPResponse() else {
        throw PiholeError.unknown("Failed to create response")
      }
      return (response, makeAuthResponse())
    }

    let session = makeSession()
    try await session.login()

    let result = try await session.authorizedRequest(alwaysSucceed)
    XCTAssertEqual(result, "test-sid")
  }
}

// MARK: - XCTest async helper

extension XCTest {
  /// Asserts that an async expression throws an error, and runs optional
  /// additional validation on the caught error.
  func assertThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    errorHandler: (any Error) -> Void = { _ in }
  ) async {
    do {
      _ = try await expression()
      XCTFail("Expected error but no error was thrown", file: file, line: line)
    } catch {
      errorHandler(error)
    }
  }
}
