import Foundation

/// Typed errors returned by Pi-hole service operations. Conforms to `LocalizedError` for user-facing messages.
enum PiholeError: Error, LocalizedError, Equatable {
  case unauthorized
  case network(String)
  case server(Int, String?)
  case tlsUntrusted
  case duplicateDomain
  case decoding(String)
  case totpRequired
  case unknown(String)

  var errorDescription: String? {
    switch self {
    case .unauthorized:
      return "Authentication failed. Check your credential."
    case .network(let description):
      return "Network error: \(description)"
    case .server(let code, let message):
      if let message {
        return "Server error (\(code)): \(message)"
      }
      return "Server error (\(code))"
    case .tlsUntrusted:
      return "Untrusted TLS certificate"
    case .duplicateDomain:
      return "Domain is already in the list"
    case .decoding(let description):
      return "Failed to parse response: \(description)"
    case .totpRequired:
      return "TOTP code required for 2FA"
    case .unknown(let description):
      return "Unexpected error: \(description)"
    }
  }
}
