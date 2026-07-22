import Foundation
import Testing

@testable import Holeberry

// swiftlint:disable non_optional_string_data_conversion

// MARK: - PiholeVersionDetector

@Suite("PiholeVersionDetector")
struct PiholeVersionDetectorTests {
  private static let baseURL = URL(string: "http://192.168.1.100")!
  private let session: URLSession
  private let detector = PiholeVersionDetector()

  init() {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SharedMockURLProtocol.self]
    session = URLSession(configuration: config)
  }

  deinit {
    SharedMockURLProtocol.requestHandler = nil
  }

  @Test("Detects v5 from 200 with version key")
  func detectsV5() async throws {
    SharedMockURLProtocol.requestHandler = { request in
      #expect(request.url?.absoluteString.contains("version") == true)
      let response = try #require(
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
      )
      let data = #"{"version":5}"#.data(using: .utf8)!
      return (response, data)
    }

    let version = try await detector.detect(baseURL: Self.baseURL, session: session)
    #expect(version == .v5)
  }

  @Test("Detects v6 from 400 with hint containing /api")
  func detectsV6() async throws {
    SharedMockURLProtocol.requestHandler = { request in
      let response = try #require(
        HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)
      )
      let data = #"{"hint":"...the API is hosted at /api...","error":{"hint":"...the API is hosted at /api..."}}"#.data(
        using: .utf8)!
      return (response, data)
    }

    let version = try await detector.detect(baseURL: Self.baseURL, session: session)
    #expect(version == .v6)
  }

  @Test("Throws on unexpected status code")
  func throwsOnUnexpectedStatus() async throws {
    SharedMockURLProtocol.requestHandler = { request in
      let response = try #require(
        HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)
      )
      return (response, Data())
    }

    await #expect(throws: PiholeError.unknown) {
      try await detector.detect(baseURL: Self.baseURL, session: session)
    }
  }

  @Test("Throws on network error")
  func throwsOnNetworkError() async throws {
    SharedMockURLProtocol.requestHandler = { _ in
      throw PiholeError.network("Connection refused")
    }

    await #expect(throws: PiholeError.network) {
      try await detector.detect(baseURL: Self.baseURL, session: session)
    }
  }

  @Test("Throws on v5 response without version key")
  func throwsOnV5WithoutVersionKey() async throws {
    SharedMockURLProtocol.requestHandler = { request in
      let response = try #require(
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
      )
      let data = #"{"something":"else"}"#.data(using: .utf8)!
      return (response, data)
    }

    await #expect(throws: PiholeError.unknown) {
      try await detector.detect(baseURL: Self.baseURL, session: session)
    }
  }

  @Test("Throws on v6 400 without hint")
  func throwsOnV6WithoutHint() async throws {
    SharedMockURLProtocol.requestHandler = { request in
      let response = try #require(
        HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)
      )
      let data = #"{"error":"bad request"}"#.data(using: .utf8)!
      return (response, data)
    }

    await #expect(throws: PiholeError.unknown) {
      try await detector.detect(baseURL: Self.baseURL, session: session)
    }
  }
}

// MARK: - ConcreteAuthSessionFactory

@Suite("ConcreteAuthSessionFactory")
struct ConcreteAuthSessionFactoryTests {
  @Test("Throws for v5")
  func throwsForV5() {
    let factory = ConcreteAuthSessionFactory()
    #expect(throws: PiholeError.unknown) {
      try factory.makeSession(
        host: URL(string: "http://test.local")!,
        password: "pass",
        urlSession: URLSession.shared,
        piHoleVersion: .v5
      )
    }
  }

  @Test("Returns AuthV6SessionProvider for v6")
  func returnsProviderForV6() throws {
    let factory = ConcreteAuthSessionFactory()
    let provider = try factory.makeSession(
      host: URL(string: "http://test.local")!,
      password: "pass",
      urlSession: URLSession.shared,
      piHoleVersion: .v6
    )
    #expect(provider is AuthV6SessionProvider)
  }
}

// MARK: - MockURLProtocol (reused by version detector and service tests)

/// Re-export of the MockURLProtocol used across multiple test files.
/// Declared in AuthV6SessionProviderTests.swift — this typealias avoids
/// redefining it, but since tests are compiled into one module we must
/// not have duplicate definitions. Use direct references from AuthV6SessionProviderTests.
///
/// For convenience, the version detector tests above use a shared MockURLProtocol
/// that is defined once in this module. We rely on the fact that all test files
/// are compiled into the same target.
// swiftlint:disable static_over_final_class
final class SharedMockURLProtocol: URLProtocol {
  nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      Issue.record("No requestHandler set")
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

/// Build an HTTPURLResponse for testing.
func makeTestHTTPResponse(statusCode: Int = 200, url: URL? = nil) -> HTTPURLResponse? {
  let url = url ?? testURL("http://192.168.1.100/test")
  return HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)
}
