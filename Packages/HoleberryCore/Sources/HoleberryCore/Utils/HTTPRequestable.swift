import Foundation

public protocol HTTPRequestable: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
  func invalidateAndCancel()
}

extension HTTPRequestable {
  func invalidateAndCancel() {}
}

extension URLSession: HTTPRequestable {}
