import Foundation

/// Pi-hole operations with managed temporary and permanent domain unblocking.
@MainActor
public protocol PiholeUnblockingServiceProviding: PiholeServiceProviding {
  @discardableResult
  func unblockDomain(_ domain: String, duration: TimeInterval?) async throws -> DomainUnblockOutcome
}
