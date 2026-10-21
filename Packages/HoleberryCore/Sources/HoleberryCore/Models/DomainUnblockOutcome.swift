/// The result of an unblock request, including changes and skipped operations.
public enum DomainUnblockOutcome: Equatable, Sendable {
  case added
  /// Another unblock for this server and domain is running; skip silently.
  case inProgress
  /// An existing temporary unblock owned by Holeberry was extended.
  case renewed
  /// An existing temporary unblock was made permanent.
  case promoted
  /// `enabled` is unknown when the existing row cannot be read.
  case alreadyPresent(enabled: Bool?)
}
