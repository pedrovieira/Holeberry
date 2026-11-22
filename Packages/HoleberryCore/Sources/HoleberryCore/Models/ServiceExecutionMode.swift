/// Controls automatic startup work when constructing DNS provider services.
public enum ServiceExecutionMode: Equatable, Sendable {
  /// Preserves the app's ongoing authentication and domain-expiry work.
  case application
  /// Skips background maintenance for short-lived read-only callers.
  /// Write operations are outside this mode's supported use; it does not enforce read-only access.
  case onDemand
}
