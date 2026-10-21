import Foundation

/// Application-facing Pi-hole operations, including temporary and permanent domain unblocking.
@MainActor
public protocol PiholeServiceProviding: PiholeAPIProviding {
  @discardableResult
  func unblockDomain(_ domain: String, duration: TimeInterval?) async throws -> DomainUnblockOutcome
}
