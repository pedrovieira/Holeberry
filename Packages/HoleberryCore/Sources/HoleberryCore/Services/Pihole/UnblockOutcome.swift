import Foundation

/// What a temp-unblock request actually achieved.
public enum UnblockOutcome: Equatable, Sendable {
  /// The domain was added now (or already carried this request's ownership token).
  case added
  /// Our own active temp record was extended to the new duration (last request wins).
  case renewed
  /// An indefinite request turned our own temp record into a permanent allowlist entry.
  case promoted
  /// An effective entry already exists and is not ours — nothing scheduled.
  case alreadyAllowed
  /// An entry exists but is disabled — the domain stays blocked; tell the user.
  case ineffective
}
