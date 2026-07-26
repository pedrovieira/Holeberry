import Foundation

@testable import Holeberry

final class MockURLSession: HTTPRequestable, @unchecked Sendable {
  /// Queue of response handlers. Each `data(for:)` call pops the next one.
  var handlers: [(URLRequest) throws -> (Data, HTTPURLResponse)] = []

  /// All requests made through this session, in order — for post-call verification.
  private(set) var requests: [URLRequest] = []

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    let handler = handlers.removeFirst()
    let (data, response) = try handler(request)
    return (data, response)
  }

  func invalidateAndCancel() {}
}
