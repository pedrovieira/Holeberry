import Foundation
import HoleberryCore
import OSLog
import WidgetKit

/// Fetches live query summaries for one configured scope.
///
/// The current All servers widget uses `.all`; a future per-server widget can
/// pass `.server(id)`. All storage access is read-only and revalidates on every
/// open; rendering stays here, fetch and storage policy stay in `HoleberryCore`.
struct QueryStatisticsProvider: TimelineProvider {
  private static let logger = Logger(subsystem: Logger.appSubsystem, category: "Widget")

  private let scope: ServerScope

  init(scope: ServerScope) {
    self.scope = scope
  }

  func placeholder(in context: Context) -> QueryStatisticsEntry {
    .placeholder(scope: scope)
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping @Sendable (QueryStatisticsEntry) -> Void
  ) {
    if context.isPreview {
      completion(.placeholder(scope: scope))
      return
    }

    Task { @MainActor in
      completion(await loadEntry(now: Date()))
    }
  }

  func getTimeline(
    in context: Context,
    completion: @escaping @Sendable (Timeline<QueryStatisticsEntry>) -> Void
  ) {
    Task { @MainActor in
      let entry = await loadEntry(now: Date())
      completion(makeTimeline(from: entry, now: Date()))
    }
  }

  @MainActor
  private func loadEntry(now: Date) async -> QueryStatisticsEntry {
    let reader = ConcreteSharedStorageReader(sharedStorage: BundleSharedStorage.widget)
    let connections: any ConnectionReading
    do {
      connections = try reader.openConnectionReader()
    } catch {
      Self.logger.error(
        "Widget shared storage setup failed: \(error.localizedDescription, privacy: .public)"
      )
      return .setupRequired(now: now, scope: scope)
    }

    let client = OnDemandQueryStatisticsClient(
      connections: connections,
      serviceFactory: ConcretePiholeServiceFactory(
        onDemand: ConcreteAuthSessionFactory()
      )
    )
    let batch = await client.fetchStatistics(scope: scope)
    // Stamp the response before awaiting logout: cleanup latency must not make
    // an older overlapping response look newer to the widget timeline.
    let observedAt = Date()
    logSummaryFailures(batch.results)
    await client.logout()

    // Readiness can change during the fetch. Reopen the server list only, after
    // the fetch and logout finished, and validate every result against it.
    let current: [ServerConfig]
    do {
      current = try reader.openServerReader().loadServers()
    } catch {
      Self.logger.error(
        "Widget shared storage readiness failed: \(error.localizedDescription, privacy: .public)"
      )
      return .setupRequired(now: now, scope: scope)
    }

    let scopedCurrent = scope.selected(from: current)
    guard scopedCurrent.elementsEqual(batch.servers, by: { $0.hasSameConnection(as: $1) }) else {
      // Includes empty-to-configured: no result from the old batch survives.
      return changedConfigurationEntry(servers: scopedCurrent)
    }
    guard !batch.servers.isEmpty else {
      return noMatchingServerEntry(now: now)
    }

    return completedEntry(
      servers: batch.servers,
      results: batch.results,
      observedAt: observedAt
    )
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
    Self.logger.error(
      "Summary fetch failed: failures=\(failures.count) categories=\(categories)"
    )
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

  private func noMatchingServerEntry(now: Date) -> QueryStatisticsEntry {
    QueryStatisticsEntry(
      date: now,
      base: QueryStatisticsSnapshot(scope: scope, setupRequired: false, observations: [])
    )
  }

  @MainActor
  private func changedConfigurationEntry(servers: [ServerConfig]) -> QueryStatisticsEntry {
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
    observedAt: Date
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
