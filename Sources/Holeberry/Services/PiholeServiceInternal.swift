import Foundation

/// Internal protocol extending `PiholeServiceProtocol` with a `comment` parameter
/// on `addDomain`. Only service implementations and the decorator know about this.
protocol PiholeServiceInternal: PiholeServiceProtocol {
  func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainEntry
}
