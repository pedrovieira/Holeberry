/// Outcome of `PiholeServiceProviding.addDomain(_:to:comment:)`.
public enum DomainAddOutcome: Sendable, Equatable {
  /// The entry was not there and is now.
  case added
  /// A matching entry already existed; no new entry was created.
  case alreadyPresent
}
