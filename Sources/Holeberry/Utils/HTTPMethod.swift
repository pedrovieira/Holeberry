import Foundation

/// HTTP request methods used by Pi-hole API calls.
enum HTTPMethod: String {
  case get = "GET"
  case post = "POST"
  case delete = "DELETE"
}
