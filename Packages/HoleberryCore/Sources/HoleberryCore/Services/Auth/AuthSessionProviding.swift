import Foundation

extension Notification.Name {
  /// Posted when a login attempt encounters a TOTP challenge.
  /// The UI should prompt the user to switch to an Application Password.
  public static let v6SessionTotpRequired = Notification.Name("v6SessionTotpRequired")
}

/// Abstraction for a Pi-hole v6 session that owns the SID/CSRF lifecycle.
///
/// Conforming types handle lazy login on first use and exactly one
/// re-authentication on a 401 response.  No proactive refresh is performed;
/// Pi-hole v6 uses sliding-window sessions so every authenticated request
/// is itself a refresh.
public protocol AuthSessionProviding: Sendable {
  /// Runs `operation` with a valid SID, re-authenticating once on 401.
  ///
  /// - If no session exists yet one is acquired first.
  /// - On a 401 response the session is re-acquired and `operation` is
  ///   retried exactly once.  If the retry also 401s
  ///   ``PiholeError/reauthenticationFailed`` is thrown.
  /// - Other non-2xx responses (including 5xx) are returned as-is; the
  ///   caller owns that inspection.
  func authorizedRequest<T>(
    _ operation: @Sendable (_ sid: String) async throws -> (T, HTTPURLResponse)
  ) async throws -> T where T: Sendable

  /// Explicitly acquire a session (login).  Idempotent if already
  /// authenticated.  Throws on invalid credentials, rate limiting, etc.
  func login() async throws

  /// Best-effort logout (DELETE /api/auth).  Safe to call multiple times.
  func logout() async
}
