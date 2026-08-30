import Foundation

/// The connection state of a single Pi-hole instance, shown in Settings → Servers.
public enum ServerConnectionState: Equatable, Sendable {
  case healthy
  case authError(reason: AuthFailureReason)
  case unreachable(lastSeen: Date?)
}

/// Why authentication failed. An enum — not copy — so labels stay localizable.
public enum AuthFailureReason: Equatable, Sendable {
  case missingCredential
  case passwordMayHaveChanged
  case authenticationFailed
  case totpRequired
  case rateLimited
  case sessionLimitReached
}

/// Terminal classification of a failed health check, applied only after the
/// request layer's own retry/reacquire logic is exhausted.
public enum ServerCheckFailure: Equatable, Sendable {
  case auth(AuthFailureReason)
  case unreachable
  case unsupported

  public static func classify(_ error: PiholeError) -> ServerCheckFailure {
    switch error {
    case .invalidCredentials, .reauthenticationFailed:
      return .auth(.passwordMayHaveChanged)
    case .missingCredential:
      return .auth(.missingCredential)
    case .unauthorized:
      return .auth(.authenticationFailed)
    case .server(let code, _) where code == 401:
      // v5: wrong token surfaces as HTTP 401 from api.php
      return .auth(.authenticationFailed)
    case .totpRequired:
      return .auth(.totpRequired)
    case .rateLimited:
      return .auth(.rateLimited)
    case .sessionLimitReached:
      return .auth(.sessionLimitReached)
    case .unsupported:
      return .unsupported
    case .network, .tlsUntrusted, .duplicateDomain, .decoding, .unknown:
      return .unreachable
    case .server:
      return .unreachable
    }
  }
}
