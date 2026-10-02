import Foundation

/// Outcome of `PiholeServiceCommentAdding.addDomain(_:to:comment:)`.
public enum DomainAddOutcome: Sendable, Equatable {
  /// The entry was not there and is now.
  case added
  /// A matching entry already existed; no new entry was created.
  case alreadyPresent
}

/// Internal domain-add API with a `comment` parameter.
/// Only service implementations and the decorator know about this.
public protocol PiholeServiceCommentAdding: PiholeServiceProviding {
  /// Adds an exact entry, skipping existing entries when possible.
  /// v5 reads first and classifies the add message; v6 reports insert outcomes in JSON.
  func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainAddOutcome
}
