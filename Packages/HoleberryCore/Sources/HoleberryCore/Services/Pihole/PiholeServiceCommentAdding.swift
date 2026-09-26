import Foundation

/// Internal protocol extending `PiholeServiceProviding` with a `comment` parameter
/// on `addDomain`. Only service implementations and the decorator know about this.
public protocol PiholeServiceCommentAdding: PiholeServiceProviding {
  func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainEntry
  /// Exact-match lookup in the allowlist. `nil` = not present.
  func allowEntry(_ domain: String) async throws -> DomainEntry?
}
