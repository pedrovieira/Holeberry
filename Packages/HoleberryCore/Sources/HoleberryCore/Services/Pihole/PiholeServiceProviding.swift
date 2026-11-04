import Foundation

/// Application-facing Pi-hole operations, including temporary and permanent domain unblocking.
@MainActor
public protocol PiholeServiceProviding: PiholeAPIProviding {
  @discardableResult
  func unblockDomain(_ domain: String, duration: TimeInterval?) async throws -> DomainUnblockOutcome

  /// Renews or promotes an existing owned entry, without ever inserting a new allowlist entry.
  @discardableResult
  func unblockExistingDomain(_ domain: String, duration: TimeInterval?) async throws -> DomainUnblockOutcome?
}
