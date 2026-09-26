import Foundation

/// What the server's reply to a domain-list add actually did.
public enum DomainListAddResult: Equatable, Sendable {
  /// The reply says this call inserted the entry (`entry` = read-back, when available).
  case inserted(DomainEntry?)
  /// The reply says the insert did not happen; `entry` is the current state
  /// (the pre-existing entry for a duplicate).
  case notInserted(DomainEntry)
}
