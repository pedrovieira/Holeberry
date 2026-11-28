import Foundation

/// Shared browser action used by the menu and keyboard shortcut.
@MainActor
public protocol BrowserDomainUnblocking: AnyObject {
  func unblock(domain: String, duration: TimeInterval?) async -> BrowserDomainUnblockResult
}

/// Aggregate outcome of the managed browser-domain unblock; history failures do not prevent a normal attempt.
public enum BrowserDomainUnblockOutcome: Equatable, Sendable {
  case processed
  case notBlocked
  case unavailable
  case noServers
  case inProgress
  case cancelled
  case failed(PiholeError)
}

/// Retains the evidence and managed outcomes for each exact hostname and server.
public struct BrowserDomainUnblockResult: Sendable {
  public let outcome: BrowserDomainUnblockOutcome
  public let requestedDomain: String
  public let candidateDomains: [String]
  /// Hostnames with confirmed ALLOW and no confirmed DENY; all mutations, including timer changes, were skipped.
  public let allowedDomains: [String]
  public let clientIP: String?
  public let serverLabels: [UUID: String]
  public let checks: [String: [UUID: Result<DomainQueryDecision, PiholeError>]]
  public let mutations: [String: [UUID: Result<DomainUnblockOutcome, PiholeError>]]

  public init(
    outcome: BrowserDomainUnblockOutcome,
    requestedDomain: String,
    candidateDomains: [String] = [],
    clientIP: String? = nil,
    serverLabels: [UUID: String] = [:],
    checks: [String: [UUID: Result<DomainQueryDecision, PiholeError>]] = [:],
    mutations: [String: [UUID: Result<DomainUnblockOutcome, PiholeError>]] = [:],
    allowedDomains: [String] = []
  ) {
    self.allowedDomains = allowedDomains
    self.outcome = outcome
    self.requestedDomain = requestedDomain
    self.candidateDomains = candidateDomains
    self.clientIP = clientIP
    self.serverLabels = serverLabels
    self.checks = checks
    self.mutations = mutations
  }
}
