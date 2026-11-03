import Foundation

/// Pi-hole's handling of a recorded query, independent of its API version.
public enum DomainQueryHandling: Equatable, Sendable {
  case ruleBlocked
  case permitted
  case upstreamBlocked
  case inconclusive
}

public struct DomainQueryEntry: Equatable, Sendable {
  public let domain: String
  public let timestamp: Date
  public let queryType: String
  public let clientIP: String
  public let handling: DomainQueryHandling
  public let status: String
  public let reply: String?

  public init(
    domain: String,
    timestamp: Date,
    queryType: String,
    clientIP: String,
    handling: DomainQueryHandling,
    status: String,
    reply: String?
  ) {
    self.domain = domain
    self.timestamp = timestamp
    self.queryType = queryType
    self.clientIP = clientIP
    self.handling = handling
    self.status = status
    self.reply = reply
  }
}

public struct DomainQueryHistory: Equatable, Sendable {
  public let entries: [DomainQueryEntry]

  /// Whether the transport exhausted the history exposed for the requested hostname, client and time window.
  ///
  /// False means coverage is incomplete, for example after a pagination cap, an unusable cursor or an explicit
  /// privacy-hidden response. The policy cannot infer no history or no block from incomplete coverage, although
  /// a confirmed latest rule block can still permit an unblock. True does not guarantee that Pi-hole settings
  /// expose every query; in particular, v5 cannot report hidden newer queries or a blocked-only log preference.
  public let isComplete: Bool

  public init(entries: [DomainQueryEntry], isComplete: Bool) {
    self.entries = entries
    self.isComplete = isComplete
  }
}

public enum DomainQueryDecision: Equatable, Sendable {
  case blocked
  case notBlocked
  case upstreamBlocked
  case noHistory
  case unavailable
}
