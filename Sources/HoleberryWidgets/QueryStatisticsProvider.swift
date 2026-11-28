import Foundation
import HoleberryCore
import OSLog
import WidgetKit

/// Fetches live query summaries for the widget's configured scope.
///
/// The configuration supplies `.all` or one saved server UUID. Every loading,
/// placeholder, and timeline path uses that scope, so a widget instance never
/// renders another instance's selection.
struct QueryStatisticsProvider: AppIntentTimelineProvider {
  typealias Intent = ServerStatisticsConfigurationIntent
  typealias Entry = QueryStatisticsEntry

  private static let logger = Logger(subsystem: Logger.appSubsystem, category: "Widget")

  func placeholder(in context: Context) -> QueryStatisticsEntry {
    .placeholder()
  }

  func snapshot(for configuration: Intent, in context: Context) async -> QueryStatisticsEntry {
    if context.isPreview {
      return .preview(for: configuration.server)
    }
    return await loadEntry(now: Date(), scope: configuration.server.scope)
  }

  func timeline(for configuration: Intent, in context: Context) async -> Timeline<QueryStatisticsEntry> {
    let entry = await loadEntry(now: Date(), scope: configuration.server.scope)
    return makeTimeline(from: entry, now: Date())
  }

  @MainActor
  private func loadEntry(now: Date, scope: ServerScope) async -> QueryStatisticsEntry {
    let reader = SharedStorageReader()
    let storage: any AppStorageProviding
    do {
      storage = try reader.openStorage()
    } catch {
      return setupRequiredEntry(now: now, scope: scope, error: error)
    }
    let manager = PiholeServerManager(
      storage: storage,
      serviceFactory: ConcretePiholeServiceFactory(
        authSessionFactory: ConcreteAuthSessionFactory()
      ),
      versionDetector: PiholeVersionDetector(),
      urlSessionFactory: ConcreteURLSessionFactory(),
      executionMode: .onDemand,
      allowsServerChanges: false
    )
    let snapshot = scopedServers(manager.servers, scope: scope)
    // Fetch only when the scope matched, then close the transports this load
    // created in one place, whatever the scope produced.
    var results: [UUID: Result<QuerySummary, PiholeError>] = [:]
    if !snapshot.isEmpty {
      results = await manager.getQuerySummary(scope: scope)
    }
    // Stamp the response before awaiting logout: cleanup latency must not make
    // an older overlapping response look newer to the widget timeline.
    let observedAt = Date()
    logSummaryFailures(results)
    await manager.logoutAll()

    // Migration readiness can change during the fetch. Only the saved list is
    // reread, so revalidation never opens the shared credential store again.
    let current: [ServerConfig]
    do {
      current = scopedServers(try reader.servers(), scope: scope)
    } catch {
      return setupRequiredEntry(now: now, scope: scope, error: error, revalidating: true)
    }
    guard current.elementsEqual(snapshot, by: { $0.hasSameConnection(as: $1) }) else {
      return changedConfigurationEntry(servers: current, scope: scope)
    }
    guard !current.isEmpty else {
      return .empty(now: now, scope: scope)
    }

    return completedEntry(
      servers: current,
      results: results,
      observedAt: observedAt,
      scope: scope
    )
  }

  private func scopedServers(_ servers: [ServerConfig], scope: ServerScope) -> [ServerConfig] {
    switch scope {
    case .all:
      return servers
    case .server(let id):
      guard let selected = servers.first(where: { $0.id == id }) else { return [] }
      return [selected]
    }
  }

  /// Logs the cause and shows guidance. Never logs credentials, response
  /// bodies, server URLs, or server UUIDs.
  @MainActor
  private func setupRequiredEntry(
    now: Date,
    scope: ServerScope,
    error: any Error,
    revalidating: Bool = false
  ) -> QueryStatisticsEntry {
    let stage = revalidating ? "revalidation" : "setup"
    Self.logger.error(
      "Widget shared storage \(stage, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
    )
    return .setupRequired(now: now, scope: scope)
  }

  /// Logs the coarse failure categories.
  /// Never logs credentials, response bodies, server URLs, or server UUIDs.
  private func logSummaryFailures(_ results: [UUID: Result<QuerySummary, PiholeError>]) {
    let failures = results.values.compactMap { result -> PiholeError? in
      guard case .failure(let error) = result else { return nil }
      return error
    }
    guard !failures.isEmpty else { return }

    let categories = Set(failures.map(Self.failureCategory)).sorted().joined(separator: ",")
    let message = "Summary fetch failed: failures=\(failures.count) categories=\(categories)"
    Self.logger.error("\(message, privacy: .public)")
  }

  private static func failureCategory(_ error: PiholeError) -> String {
    switch error {
    case .unauthorized, .invalidCredentials, .missingCredential:
      return "credential"
    case .server(let code, _):
      return "server-\(code)"
    case .network, .tlsUntrusted:
      return "network"
    case .decoding:
      return "decoding"
    case .totpRequired:
      return "totpRequired"
    case .rateLimited, .sessionLimitReached:
      return "rateLimited"
    case .reauthenticationFailed:
      return "reauthenticationFailed"
    case .invalidDomain, .unknown, .unsupported:
      return "other"
    }
  }

  @MainActor
  private func changedConfigurationEntry(servers: [ServerConfig], scope: ServerScope) -> QueryStatisticsEntry {
    QueryStatisticsEntry(
      date: Date(),
      base: QueryStatisticsSnapshot(
        scope: scope,
        setupRequired: false,
        // A configuration change invalidates the fetch, so no old result survives it.
        observations: ServerQueryObservation.make(servers: servers, results: [:], checkedAt: nil)
      )
    )
  }

  @MainActor
  private func completedEntry(
    servers: [ServerConfig],
    results: [UUID: Result<QuerySummary, PiholeError>],
    observedAt: Date,
    scope: ServerScope
  ) -> QueryStatisticsEntry {
    QueryStatisticsEntry(
      date: observedAt,
      base: QueryStatisticsSnapshot(
        scope: scope,
        setupRequired: false,
        observations: ServerQueryObservation.make(
          servers: servers,
          results: results,
          checkedAt: observedAt
        )
      )
    )
  }

  private func makeTimeline(
    from entry: QueryStatisticsEntry,
    now: Date
  ) -> Timeline<QueryStatisticsEntry> {
    let nextFetch = now.addingTimeInterval(15 * 60)
    // Entries that only advance the footer keep the batch snapshot, so the
    // counts and the footer's update age come from the same fetch.
    let currentEntry = QueryStatisticsEntry(date: now, base: entry.base)
    let footerDates = WidgetFooter.entryDates(
      observedAt: entry.lastCheckedAt,
      now: now
    )
    let footerEntries = footerDates.map { date in
      QueryStatisticsEntry(date: date, base: entry.base)
    }

    return Timeline(
      entries: [currentEntry] + footerEntries,
      policy: .after(nextFetch)
    )
  }
}
