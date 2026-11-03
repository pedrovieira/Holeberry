import Foundation

/// Checks recent client-scoped evidence before allowing new browser-triggered entries.
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
    guard let clientIP = request.clientIP else { return request.result(.missingClientIP) }
    guard !Task.isCancelled else { return request.result(.cancelled) }

    return await perform(request, clientIP: clientIP, duration: duration)
  }

  private func perform(_ initialRequest: Request, clientIP: String, duration: TimeInterval?) async
    -> BrowserDomainUnblockResult
  {
    var request = initialRequest
    let histories = await manager.getDomainQueryHistory(
      domains: request.candidates, forClientIP: clientIP, interval: request.interval)
    let checks = evaluate(histories, request: request, clientIP: clientIP)
    var mutations: Mutations = [:]
    for domain in request.candidates {
      guard !Task.isCancelled else { break }
      let blocked =
        checks[domain]?.values.contains { result in
          if case .success(.blocked) = result { return true }
          return false
        } == true
      // Each manager call targets its current servers. Keep labels for any that joined since the read.
      for server in manager.servers where request.serverLabels[server.id] == nil {
        request.serverLabels[server.id] = manager.displayLabel(for: server.id) ?? server.label ?? server.url
      }
      mutations[domain] = await manager.applyDomainUnblock(
        domain: domain,
        duration: duration,
        mode: blocked ? .allowCreation : .existingOnly)
    }
    return request.result(outcome(checks: checks, mutations: mutations), checks: checks, mutations: mutations)
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

  private func outcome(checks: Checks, mutations: Mutations) -> BrowserDomainUnblockOutcome {
    let writes = mutations.values.flatMap(\.values)
    if writes.contains(where: { result in
      if case .success(let outcome?) = result { return outcome != .inProgress }
      return false
    }) {
      return .processed
    }
    // Completed writes stay visible when cancellation stops the remaining candidates.
    if Task.isCancelled { return .cancelled }
    let reads = checks.values.flatMap(\.values)
    let decisions = reads.compactMap { try? $0.get() }
    if reads.contains(where: {
      if case .failure = $0 { return true }
      return false
    })
      || writes.contains(where: {
        if case .failure = $0 { return true }
        return false
      })
      || decisions.contains(.unavailable)
    {
      return .unavailable
    }
    if writes.contains(where: {
      if case .success(.inProgress) = $0 { return true }
      return false
    }) {
      return .inProgress
    }
    return negativeOutcome(decisions)
  }

  private func negativeOutcome(_ decisions: [DomainQueryDecision]) -> BrowserDomainUnblockOutcome {
    // A confirmed block should have produced a row outcome or an explicit failure.
    if decisions.contains(.blocked) { return .unavailable }
    if decisions.contains(.upstreamBlocked) { return .upstreamBlocked }
    if decisions.contains(.notBlocked) { return .notBlocked }
    return .noHistory
  }

  private struct Request {
    let domain: String
    let candidates: [String]
    let clientIP: String?
    var serverLabels: [UUID: String]
    let interval: DateInterval

    var serverIDs: Set<UUID> { Set(serverLabels.keys) }

    func result(
      _ outcome: BrowserDomainUnblockOutcome, checks: Checks = [:], mutations: Mutations = [:]
    ) -> BrowserDomainUnblockResult {
      BrowserDomainUnblockResult(
        outcome: outcome,
        requestedDomain: domain,
        candidateDomains: candidates,
        clientIP: clientIP,
        serverLabels: serverLabels,
        checks: checks,
        mutations: mutations)
    }
  }
}
