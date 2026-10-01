import Foundation

/// Outcome of `PiholeServiceCommentAdding.addDomain(_:to:comment:)`.
public enum DomainAddOutcome: Sendable, Equatable {
  /// The entry was not there and is now.
  case added
  /// A matching entry already existed, so nothing was written.
  case alreadyPresent
}

/// Internal domain-add API with a `comment` parameter.
/// Only service implementations and the decorator know about this.
public protocol PiholeServiceCommentAdding: PiholeServiceProviding {
  /// Adds an exact entry while preserving an existing entry and its comment.
  /// v5 reads the list before writing; v6 reports insert outcomes in JSON.
  func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainAddOutcome
}
