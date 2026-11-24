import Foundation

/// One on-demand query-summary batch for a scope.
public struct QueryStatisticsBatch: Equatable, Sendable {
  /// The selected configured servers, in saved order.
  public let servers: [ServerConfig]
  /// One outcome per selected server. A server whose service could not be built
  /// keeps its failure, so a caller can still show its identity.
  public let results: [UUID: Result<QuerySummary, PiholeError>]

  public init(servers: [ServerConfig], results: [UUID: Result<QuerySummary, PiholeError>]) {
    self.servers = servers
    self.results = results
  }
}

/// Read-only statistics access for short-lived callers such as the widget.
///
/// Fetch and logout are separate so a caller can stamp the response time before
/// awaiting cleanup. Logout is the caller's responsibility on every exit path.
@MainActor
public protocol QueryStatisticsFetching {
  /// Scopes the saved connections, builds only the selected services, and reads
  /// one summary from each. Never authenticates ahead of a request.
  func fetchStatistics(scope: ServerScope) async -> QueryStatisticsBatch
  /// Logs out and discards every service built by earlier fetches.
  func logout() async
}

/// Fetches query summaries without a writable server manager.
///
/// It reads only `ConnectionReading`, so a caller cannot store servers, rewrite
/// credentials, or touch app-local temporary-unblock records. Service
/// construction goes through the on-demand factory, which owns the policy that
/// no local persistence is used and no auth warm-up runs.
///
/// Every transport it creates is released: a session whose build throws is
/// invalidated at once, and `logout()` invalidates the rest after their logout
/// requests finish.
///
/// `logout()` runs service cleanup in a fresh task whose cancellation state is
/// independent of the caller. A widget refresh can be cancelled at any moment, and
/// starting the session `DELETE` from an already-cancelled task can prevent it
/// from reaching the server, so session cleanup must not inherit that
/// cancellation.
@MainActor
public final class OnDemandQueryStatisticsClient: QueryStatisticsFetching {
  /// Waits out the cleanup budget. Injected so tests can prove the bound without
  /// a real clock.
  public typealias CleanupDeadline = @MainActor @Sendable () async -> Void

  /// Longest wait for service logout before transports are released.
  ///
  /// The v6 session `DELETE` has a 10 s request timeout, so this budget lets a
  /// healthy cleanup finish and still bounds a wedged one.
  public static let defaultCleanupBudget: Duration = .seconds(15)

  private let connections: any ConnectionReading
  private let serviceFactory: any PiholeServiceFactory
  private let sessionFactory: any URLSessionFactory
  private let cleanupDeadline: CleanupDeadline
  private var builtServices: [any PiholeServiceProviding] = []
  private var builtSessions: [any HTTPRequestable] = []

  public init(
    connections: any ConnectionReading,
    serviceFactory: any PiholeServiceFactory,
    sessionFactory: any URLSessionFactory = ConcreteURLSessionFactory(),
    cleanupDeadline: @escaping CleanupDeadline = {
      try? await ContinuousClock().sleep(for: OnDemandQueryStatisticsClient.defaultCleanupBudget)
    }
  ) {
    self.connections = connections
    self.serviceFactory = serviceFactory
    self.sessionFactory = sessionFactory
    self.cleanupDeadline = cleanupDeadline
  }

  public func fetchStatistics(scope: ServerScope) async -> QueryStatisticsBatch {
    let savedServers = connections.loadServers()
    let selected = scope.selected(from: savedServers)
    guard !selected.isEmpty else { return QueryStatisticsBatch(servers: [], results: [:]) }

    // One trusted-host set for the whole batch, as the app builds for its own
    // sessions: every configured host is user-approved, regardless of scope.
    let trustedHosts = Set(savedServers.compactMap { URL(string: $0.url)?.host })

    var results: [UUID: Result<QuerySummary, PiholeError>] = [:]
    var selectedServices: [UUID: any PiholeServiceProviding] = [:]

    for config in selected {
      let credential: String
      do {
        // A failed read is a failure, not absence: never fall back to the
        // passwordless path when the stored credential is merely unreadable.
        credential = try connections.readCredential(for: config.id) ?? ""
      } catch {
        results[config.id] = .failure(Self.piholeError(from: error))
        continue
      }

      let session = sessionFactory.makeSession(configuration: .ephemeral, trustedHosts: trustedHosts)
      do {
        let service = try serviceFactory.buildService(
          config: config,
          credential: credential,
          session: session
        )
        selectedServices[config.id] = service
        // Record the pair before fetching, so logout covers a fetch that never
        // returns and still has a transport for its own request.
        builtServices.append(service)
        builtSessions.append(session)
      } catch {
        // No service owns this transport, so nothing else will release it.
        session.invalidateAndCancel()
        results[config.id] = .failure(Self.piholeError(from: error))
      }
    }

    // Same concurrent execution and error mapping as the app manager; only
    // successfully built services enter the batch, and credential/build
    // failures recorded above are never overwritten.
    let fetched = await performPiholeOperation(
      serverIDs: Array(selectedServices.keys),
      services: selectedServices
    ) { service in
      try await service.getQuerySummary()
    }
    results.merge(fetched) { current, _ in current }

    return QueryStatisticsBatch(servers: selected, results: results)
  }

  public func logout() async {
    let services = builtServices
    let sessions = builtSessions
    builtServices.removeAll()
    builtSessions.removeAll()
    guard !services.isEmpty || !sessions.isEmpty else { return }

    // Fresh unstructured work: a cancelled caller must not cancel the session
    // DELETE that ends this cleanup.
    let cleanup = Task { @MainActor in
      await withTaskGroup(of: Void.self) { group in
        for service in services {
          group.addTask {
            await service.logout()
          }
        }
      }
    }
    await awaitCleanup(cleanup)

    // Invalidate only after cleanup finished or its budget elapsed, so cleanup
    // requests could still use their transport. A second logout finds nothing
    // to repeat.
    for session in sessions {
      session.invalidateAndCancel()
    }
  }

  /// Awaits `cleanup`, giving up after the injected budget.
  ///
  /// The waiters are unstructured, so neither the deadline nor the caller's own
  /// cancellation can cancel the cleanup task.
  private func awaitCleanup(_ cleanup: Task<Void, Never>) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let waiter = QueryStatisticsCleanupWaiter(continuation)
      let deadline = Task { @MainActor in
        await cleanupDeadline()
        waiter.resume()
      }
      Task { @MainActor in
        await cleanup.value
        deadline.cancel()
        waiter.resume()
      }
    }
  }

  private static func piholeError(from error: any Error) -> PiholeError {
    error as? PiholeError ?? .unknown(error.localizedDescription)
  }
}

/// Resumes a checked continuation once, whichever waiter wins the race.
@MainActor
private final class QueryStatisticsCleanupWaiter {
  private var continuation: CheckedContinuation<Void, Never>?

  init(_ continuation: CheckedContinuation<Void, Never>) {
    self.continuation = continuation
  }

  func resume() {
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume()
  }
}
