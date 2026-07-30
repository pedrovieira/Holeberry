import Foundation

/// HTTP request methods used by Pi-hole API calls.
public enum HTTPMethod: String, Sendable {
  case get = "GET"
  case post = "POST"
  case delete = "DELETE"
}
