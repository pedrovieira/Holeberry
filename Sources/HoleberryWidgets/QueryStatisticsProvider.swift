import Defaults
import Foundation
import HoleberryCore
import OSLog
import WidgetKit

/// Fetches live query summaries for one configured scope.
///
/// The current All servers widget uses `.all`; a future per-server widget can
/// pass `.server(id)`.
struct QueryStatisticsProvider: TimelineProvider {
  private static let logger = Logger(subsystem: Logger.appSubsystem, category: "Widget")

  private let scope: ServerScope

  init(scope: ServerScope) {
    self.scope = scope
  }

  func placeholder(in context: Context) -> QueryStatisticsEntry {
    .placeholder()
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping @Sendable (QueryStatisticsEntry) -> Void
  ) {
    if context.isPreview {
      completion(.placeholder())
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
      let now = Date()
      let entry = await loadEntry(now: now)
      completion(makeTimeline(from: entry, now: now))
    }
  }

  @MainActor
  private func loadEntry(now: Date) async -> QueryStatisticsEntry {
    guard
      let appGroupIdentifier = try? Bundle.main.sharedAppGroupIdentifier(),
      let keychainAccessGroup = try? Bundle.main.sharedKeychainAccessGroup(),
      let suite = try? UserDefaults.sharedStorageSuite(
        appGroupIdentifier: appGroupIdentifier
      )
    else {
      return .setupRequired(now: now)
    }
    _ = suite.synchronize()
    guard SharedStorageMigration.isComplete(in: suite) else {
      return .setupRequired(now: now)
    }

    let manager = PiholeServerManager(
      keychain: KeychainManager.shared(
        accessGroup: keychainAccessGroup,
        interactive: false
      ),
      serviceFactory: ConcretePiholeServiceFactory(
        authSessionFactory: ConcreteAuthSessionFactory()
      ),
      versionDetector: PiholeVersionDetector(),
      suite: suite,
      executionMode: .onDemand
    )
    let snapshot = scopedIdentities(manager.servers)
    guard !snapshot.isEmpty else {
      return noMatchingServerEntry(now: now)
    }

    let results = await manager.getQuerySummary(scope: scope)
    // Stamp the response before awaiting logout: cleanup latency must not make
    // an older overlapping response look newer to the widget timeline.
    let observedAt = Date()
    logSummaryFailures(results)
    await manager.logoutAll()
    _ = suite.synchronize()

    let current = scopedIdentities(Defaults[.servers(suite: suite)])
    guard current == snapshot else {
      return changedConfigurationEntry(servers: current)
    }

    return completedEntry(
      servers: snapshot,
      results: results,
      observedAt: observedAt
    )
  }

  private func scopedIdentities(_ servers: [ServerConfig]) -> [WidgetServerIdentity] {
    switch scope {
    case .all:
      return servers.map { WidgetServerIdentity(server: $0) }
    case .server(let id):
      guard let selected = servers.first(where: { $0.id == id }) else { return [] }
      return [WidgetServerIdentity(server: selected)]
    }
  }

  /// Logs the coarse failure categories and the service used for credentials.
  /// Never logs credentials, response bodies, server URLs, or server UUIDs.
  private func logSummaryFailures(_ results: [UUID: Result<QuerySummary, PiholeError>]) {
    let failures = results.values.compactMap { result -> PiholeError? in
      guard case .failure(let error) = result else { return nil }
      return error
    }
    guard !failures.isEmpty else { return }

    let categories = Set(failures.map(Self.failureCategory)).sorted().joined(separator: ",")
    let message =
      "Summary fetch failed: failures=\(failures.count) categories=\(categories) "
      + "credentialService=\(KeychainManager.sharedService)"
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

  private func noMatchingServerEntry(now: Date) -> QueryStatisticsEntry {
    let summary = WidgetSummary(servers: [], results: [:], checkedAt: nil)
    return QueryStatisticsEntry(date: now, setupRequired: false, summary: summary)
  }

  @MainActor
  private func changedConfigurationEntry(servers: [WidgetServerIdentity]) -> QueryStatisticsEntry {
    let summary = WidgetSummary(servers: servers, results: [:], checkedAt: nil)
    return QueryStatisticsEntry(date: Date(), setupRequired: false, summary: summary)
  }

  @MainActor
  private func completedEntry(
    servers: [WidgetServerIdentity],
    results: [UUID: Result<QuerySummary, PiholeError>],
    observedAt: Date
  ) -> QueryStatisticsEntry {
    let summary = WidgetSummary(
      servers: servers,
      results: results,
      checkedAt: observedAt
    )
    return QueryStatisticsEntry(date: observedAt, setupRequired: false, summary: summary)
  }

  private func makeTimeline(
    from entry: QueryStatisticsEntry,
    now: Date
  ) -> Timeline<QueryStatisticsEntry> {
    let nextFetch = now.addingTimeInterval(15 * 60)
    let currentEntry = QueryStatisticsEntry(
      date: now,
      setupRequired: entry.setupRequired,
      summary: entry.summary
    )
    let footerEntries = footerEntryDates(
      observedAt: entry.presentation.lastCheckedAt,
      now: now
    ).map {
      QueryStatisticsEntry(
        date: $0,
        setupRequired: entry.setupRequired,
        summary: entry.summary
      )
    }

    return Timeline(
      entries: [currentEntry] + footerEntries,
      policy: .after(nextFetch)
    )
  }

  /// One entry per minute until the next fetch, then a coarse fallback up to
  /// the one-hour health expiry. Each entry carries static footer text, so the
  /// label advances without a network request and without a custom
  /// `FormatStyle`, which WidgetKit cannot unarchive.
  private func footerEntryDates(observedAt: Date?, now: Date) -> [Date] {
    guard let observedAt else { return [] }

    var dates = Set<Date>()
    for minute in 1...15 {
      dates.insert(observedAt.addingTimeInterval(Double(minute) * 60))
    }
    for minute in stride(from: 20, through: 60, by: 5) {
      dates.insert(observedAt.addingTimeInterval(Double(minute) * 60))
    }
    return dates.filter { $0 > now }.sorted()
  }
}
