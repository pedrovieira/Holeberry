import Foundation
import Testing

@testable import Holeberry

// swiftlint:disable non_optional_string_data_conversion

// MARK: - PiholeVersionDetector

@Suite("PiholeVersionDetector")
final class PiholeVersionDetectorTests {
  private static let baseURL = URL(string: "http://192.168.1.100")!
  private let mockSession = MockURLSession()
  private let detector = PiholeVersionDetector()

  private func makeResponse(statusCode: Int = 200) -> HTTPURLResponse? {
    HTTPURLResponse(url: Self.baseURL, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)
  }

  // MARK: - V5 detection

  @Test("Detects v5 from 200 with version key")
  func detectsV5() async throws {
    mockSession.handlers = [
      { request in
        #expect(request.url?.absoluteString.contains("version") == true)
        let response = try #require(self.makeResponse())
        let data = #"{"version":5}"#.data(using: .utf8)!
        return (data, response)
      }
    ]
    let version = try await detector.detect(baseURL: Self.baseURL, session: mockSession)
    #expect(version == .v5)
  }

  @Test("Detects v6 from 400 with hint containing /api")
  func detectsV6() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(self.makeResponse(statusCode: 400))
        let data = #"{"hint":"...the API is hosted at /api...","error":{"hint":"...the API is hosted at /api..."}}"#
          .data(using: .utf8)!
        return (data, response)
      }
    ]
    let version = try await detector.detect(baseURL: Self.baseURL, session: mockSession)
    #expect(version == .v6)
  }

  @Test("Throws on unexpected status code")
  func throwsOnUnexpectedStatus() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(self.makeResponse(statusCode: 404))
        return (Data(), response)
      }
    ]
    await #expect {
      try await detector.detect(baseURL: Self.baseURL, session: mockSession)
    } throws: { error in
      guard case PiholeError.unknown = error else {
        Issue.record("Expected .unknown, got \(error)")
        return false
      }
      return true
    }
  }

  @Test("Throws on network error")
  func throwsOnNetworkError() async throws {
    mockSession.handlers = [
      { _ in
        throw PiholeError.network("Connection refused")
      }
    ]
    await #expect(throws: PiholeError.network("Network error: Connection refused")) {
      try await detector.detect(baseURL: Self.baseURL, session: mockSession)
    }
  }

  @Test("Throws on v5 response without version key")
  func throwsOnV5WithoutVersionKey() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(self.makeResponse())
        let data = #"{"something":"else"}"#.data(using: .utf8)!
        return (data, response)
      }
    ]
    await #expect {
      try await detector.detect(baseURL: Self.baseURL, session: mockSession)
    } throws: { error in
      guard case PiholeError.unknown = error else {
        Issue.record("Expected .unknown, got \(error)")
        return false
      }
      return true
    }
  }

  @Test("Throws on random HTML page (non-Pi-hole server)")
  func randomHTMLPage() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(self.makeResponse())
        let data = Data("<html><body>Welcome to my nginx server</body></html>".utf8)
        return (data, response)
      }
    ]
    await #expect {
      try await detector.detect(baseURL: Self.baseURL, session: mockSession)
    } throws: { error in
      guard case PiholeError.unknown = error else {
        Issue.record("Expected .unknown, got \(error)")
        return false
      }
      return true
    }
  }

  @Test("Throws on v6 400 without hint")
  func throwsOnV6WithoutHint() async throws {
    mockSession.handlers = [
      { _ in
        let response = try #require(self.makeResponse(statusCode: 400))
        let data = #"{"error":"bad request"}"#.data(using: .utf8)!
        return (data, response)
      }
    ]
    await #expect {
      try await detector.detect(baseURL: Self.baseURL, session: mockSession)
    } throws: { error in
      guard case PiholeError.unknown = error else {
        Issue.record("Expected .unknown, got \(error)")
        return false
      }
      return true
    }
  }
}
