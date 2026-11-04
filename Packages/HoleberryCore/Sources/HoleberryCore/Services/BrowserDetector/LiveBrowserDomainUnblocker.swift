import Foundation

/// Skips new entries only when recent client-scoped evidence confirms allowed queries.
@MainActor
public final class LiveBrowserDomainUnblocker: BrowserDomainUnblocking {
  private typealias Checks = [String: [UUID: Result<DomainQueryDecision, PiholeError>]]
  private typealias Mutations = [String: [UUID: Result<DomainUnblockOutcome?, PiholeError>]]

  private let manager: any PiholeServerManaging
  private let networkInterface: any LocalIPAddressProviding
  private let now: () -> Date
  private var inFlightCandidates: Set<Set<String>> = []

  public init(
    manager: any PiholeServerManaging,
    networkInterface: any LocalIPAddressProviding,
    now: @escaping () -> Date = Date.init
  ) {
    self.manager = manager
    self.networkInterface = networkInterface
    self.now = now
  }

  public func unblock(domain: String, duration: TimeInterval?) async -> BrowserDomainUnblockResult {
    let candidates: [String]
    do {
      candidates = try BrowserDomainUnblockPolicy.candidates(for: domain)
    } catch {
      return BrowserDomainUnblockResult(outcome: .failed(.invalidDomain(domain)), requestedDomain: domain)
    }
    let key = Set(candidates)
    guard inFlightCandidates.insert(key).inserted else {
      return BrowserDomainUnblockResult(outcome: .inProgress, requestedDomain: domain, candidateDomains: candidates)
    }
    defer { inFlightCandidates.remove(key) }

    let end = now()
    let labels = Dictionary(
      uniqueKeysWithValues: manager.servers.map { server in
        (server.id, manager.displayLabel(for: server.id) ?? server.label ?? server.url)
      })
    let request = Request(
      domain: domain,
      candidates: candidates,
      clientIP: networkInterface.localIPAddress(),
      serverLabels: labels,
      interval: DateInterval(start: end.addingTimeInterval(-900), end: end))
    guard !request.serverIDs.isEmpty else { return request.result(.noServers) }
    guard !Task.isCancelled else { return request.result(.cancelled) }

    return await perform(request, duration: duration)
  }

  private func perform(_ initialRequest: Request, duration: TimeInterval?) async
    -> BrowserDomainUnblockResult
  {
    var request = initialRequest
    var checks: Checks = [:]
    if let clientIP = request.clientIP {
      let histories = await manager.getDomainQueryHistory(
        domains: request.candidates, forClientIP: clientIP, interval: request.interval)
      checks = evaluate(histories, request: request, clientIP: clientIP)
    }
    var mutations: Mutations = [:]
    var allowedDomains: [String] = []
    for domain in request.candidates {
      guard !Task.isCancelled else { break }
      let results = checks[domain] ?? [:]
      // One server's ALLOW for this client is sufficient; other servers need not have handled the query.
      let allowed = results.values.contains { (try? $0.get()) == .notBlocked }
      if allowed { allowedDomains.append(domain) }
      // Each manager call targets its current servers. Keep labels for any that joined since the read.
      for server in manager.servers where request.serverLabels[server.id] == nil {
        request.serverLabels[server.id] = manager.displayLabel(for: server.id) ?? server.label ?? server.url
      }
      mutations[domain] = await manager.applyDomainUnblock(
        domain: domain,
        duration: duration,
        mode: allowed ? .existingOnly : .allowCreation)
    }
    return request.result(
      outcome(allowedDomains: allowedDomains, mutations: mutations),
      checks: checks,
      mutations: mutations,
      allowedDomains: allowedDomains)
  }

  private func evaluate(
    _ histories: [String: [UUID: Result<DomainQueryHistory, PiholeError>]], request: Request, clientIP: String
  ) -> Checks {
    var checks: Checks = [:]
    for domain in request.candidates {
      var results: [UUID: Result<DomainQueryDecision, PiholeError>] = [:]
      for id in request.serverIDs {
        guard let history = histories[domain]?[id] else {
          results[id] = .failure(.unknown("No query history result was returned."))
          continue
        }
        results[id] = history.map {
          BrowserDomainUnblockPolicy.evaluate($0, domain: domain, clientIP: clientIP, interval: request.interval)
        }
      }
      checks[domain] = results
    }
    return checks
  }

  private func outcome(allowedDomains: [String], mutations: Mutations) -> BrowserDomainUnblockOutcome {
    let writes = mutations.values.flatMap(\.values)
    let outcomes = writes.compactMap { try? $0.get() }
    if outcomes.contains(where: { [.added, .renewed, .promoted].contains($0) }) {
      return .processed
    }
    // Completed changes stay visible when cancellation stops the remaining candidates.
    if Task.isCancelled { return .cancelled }
    if writes.contains(where: {
      if case .failure = $0 { return true }
      return false
    }) {
      return .unavailable
    }
    // Existing or busy sibling entries must not hide the ALLOW diagnostic.
    if !allowedDomains.isEmpty { return .notBlocked }
    if outcomes.contains(.inProgress) {
      return .inProgress
    }
    if outcomes.contains(where: {
      if case .alreadyPresent = $0 { return true }
      return false
    }) {
      return .processed
    }
    return .unavailable
  }

  private struct Request {
    let domain: String
    let candidates: [String]
    let clientIP: String?
    var serverLabels: [UUID: String]
    let interval: DateInterval

    var serverIDs: Set<UUID> { Set(serverLabels.keys) }

    func result(
      _ outcome: BrowserDomainUnblockOutcome,
      checks: Checks = [:],
      mutations: Mutations = [:],
      allowedDomains: [String] = []
    ) -> BrowserDomainUnblockResult {
      BrowserDomainUnblockResult(
        outcome: outcome,
        requestedDomain: domain,
        candidateDomains: candidates,
        clientIP: clientIP,
        serverLabels: serverLabels,
        checks: checks,
        mutations: mutations,
        allowedDomains: allowedDomains)
    }
  }
}
