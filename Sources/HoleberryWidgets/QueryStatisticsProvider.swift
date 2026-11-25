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
    let appGroupIdentifier: String
    let keychainAccessGroup: String
    let suite: UserDefaults
    let sharedKeychain: KeychainManager
    do {
      appGroupIdentifier = try Bundle.main.sharedAppGroupIdentifier()
      keychainAccessGroup = try Bundle.main.sharedKeychainAccessGroup()
      suite = try UserDefaults.sharedStorageSuite(
        appGroupIdentifier: appGroupIdentifier
      )
      sharedKeychain = try KeychainManager.shared(
        accessGroup: keychainAccessGroup,
        interactive: false
      )
    } catch {
      Self.logger.error(
        "Widget shared storage setup failed: \(error.localizedDescription, privacy: .public)"
      )
      return .setupRequired(now: now, scope: scope)
    }
    guard isSharedStorageReady(in: suite, suiteName: appGroupIdentifier) else {
      return .setupRequired(now: now, scope: scope)
    }

    let storage = ConcreteAppStorage(
      sharedDataSuite: suite,
      // On-demand execution never stores app-local temporary-unblock records;
      // the widget's own defaults keep any accidental write out of the app.
      appLocalSuite: .standard,
      keychain: sharedKeychain
    )
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
    let snapshot = scopedServers(manager.servers)
    guard !snapshot.isEmpty else {
      return noMatchingServerEntry(now: now)
    }

    let results = await manager.getQuerySummary(scope: scope)
    // Stamp the response before awaiting logout: cleanup latency must not make
    // an older overlapping response look newer to the widget timeline.
    let observedAt = Date()
    logSummaryFailures(results, credentialService: sharedKeychain.service)
    await manager.logoutAll()

    // Migration readiness can change during the fetch.
    guard isSharedStorageReady(in: suite, suiteName: appGroupIdentifier) else {
      return .setupRequired(now: now, scope: scope)
    }

    let current = scopedServers(storage.loadServers())
    guard current.elementsEqual(snapshot, by: { $0.hasSameConnection(as: $1) }) else {
      return changedConfigurationEntry(servers: current)
    }

    return completedEntry(
      servers: snapshot,
      results: results,
      observedAt: observedAt
    )
  }

  @MainActor
  private func isSharedStorageReady(in suite: UserDefaults, suiteName: String) -> Bool {
    do {
      return try SharedStorageMigration.readiness(in: suite, suiteName: suiteName) == .ready
    } catch {
      Self.logger.error("Widget shared storage readiness failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  private func scopedServers(_ servers: [ServerConfig]) -> [ServerConfig] {
    switch scope {
    case .all:
      return servers
    case .server(let id):
      guard let selected = servers.first(where: { $0.id == id }) else { return [] }
      return [selected]
    }
  }

  /// Logs the coarse failure categories and the service used for credentials.
  /// Never logs credentials, response bodies, server URLs, or server UUIDs.
  private func logSummaryFailures(
    _ results: [UUID: Result<QuerySummary, PiholeError>],
    credentialService: String
  ) {
    let failures = results.values.compactMap { result -> PiholeError? in
      guard case .failure(let error) = result else { return nil }
      return error
    }
    guard !failures.isEmpty else { return }

    let categories = Set(failures.map(Self.failureCategory)).sorted().joined(separator: ",")
    let message =
      "Summary fetch failed: failures=\(failures.count) categories=\(categories) "
      + "credentialService=\(credentialService)"
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
