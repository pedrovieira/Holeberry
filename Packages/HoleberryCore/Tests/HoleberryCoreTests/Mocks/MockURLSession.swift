import Foundation

@testable import HoleberryCore

final class MockURLSession: HTTPRequestable, @unchecked Sendable {
  /// A handler can throw `Mismatch.declined` to decline a request without
  /// consuming itself; `data(for:)` then tries the next handler in the queue.
  enum Mismatch: Error {
    case declined
  }

  /// Queue of response handlers. Each `data(for:)` call pops the next one,
  /// unless it declines the request.
  var handlers: [(URLRequest) throws -> (Data, HTTPURLResponse)] = []

  /// All requests made through this session, in order — for post-call verification.
  private(set) var requests: [URLRequest] = []

  /// Tracks how many times `invalidateAndCancel` was called.
  private(set) var invalidateAndCancelCallCount = 0

  private let lock = NSLock()

  /// Runs on the main actor so concurrent callers (e.g. the 254 parallel subnet
  /// checks in `PiholeDiscoveryService`) serialize their state access instead of
  /// racing on `requests`/`handlers`, and so handler closures — which capture
  /// `@MainActor` test state — always execute on the main actor.
  @MainActor
  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    let initialCount = handlers.count
    var tried = 0
    while tried < initialCount {
      let handler = handlers.removeFirst()
      tried += 1
      do {
        let (data, response) = try handler(request)
        return (data, response)
      } catch Mismatch.declined {
        // Handler does not serve this request — keep it for a later one.
        handlers.append(handler)
      }
    }
    // No handler served the request (all declined or queue exhausted):
    // behave like an unreachable host, matching production `URLSession` behavior.
    throw URLError(.notConnectedToInternet)
  }

  func invalidateAndCancel() {
    lock.lock()
    invalidateAndCancelCallCount += 1
    lock.unlock()
  }
}
