import Foundation

public protocol HTTPRequestable: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
  func invalidateAndCancel()
  /// Finishes in-flight work, then invalidates without cancelling it.
  func finishTasksAndInvalidate()
}

extension HTTPRequestable {
  func invalidateAndCancel() {}
}

extension URLSession: HTTPRequestable {}
