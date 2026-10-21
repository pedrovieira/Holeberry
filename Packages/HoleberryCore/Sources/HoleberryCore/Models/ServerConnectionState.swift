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
