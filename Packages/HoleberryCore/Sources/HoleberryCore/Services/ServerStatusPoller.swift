import Combine
import Defaults
import Foundation
import OSLog

// swiftlint:disable file_length

/// Result of a gravity update attempt for a single server.
public enum GravityUpdateOutcome: Equatable, Sendable {
  /// Request completed and the server's gravity timestamp moved.
  case succeeded
  /// Request completed but the gravity timestamp did not move — the update
  /// likely failed server-side.
  case noChange
  /// The request itself failed (network, auth, server error).
  case failed(PiholeError)
}

@MainActor
public final class ServerStatusPoller: ObservableObject {
  @Published public var servers: [ServerConfig] = []
  @Published public var connectionStatuses: [UUID: ConnectionStatus] = [:]
  @Published public var blockingStatuses: [UUID: BlockingStatus] = [:]
  @Published public var querySummaries: [UUID: QuerySummary] = [:]
  @Published public var lastPollError: String?
  @Published public var recentBlocked: [BlockedDomain] = []
  @Published public var connectionStates: [UUID: ServerConnectionState] = [:]
  @Published public var checkingServerIDs: Set<UUID> = []
  @Published public private(set) var isGravityUpdating = false
  private var lastSuccessfulCheck: [UUID: Date] = [:]

  /// App-observed gravity completion times; display clamps to these because
  /// Pi-hole stamps `last_update` mid-run, before its slow index-build tail.
  public private(set) var gravityCompletedAt: [UUID: Date] = [:]

  /// Concurrency guard for trigger+verify; separate from the user-visible
  /// `isGravityUpdating`, which only covers the trigger phase.
  private var gravityOperationInFlight = false

  private let logger = Logger(subsystem: Logger.appSubsystem, category: "status-monitor")
  private let pollingInterval: TimeInterval
  private let scheduler: any PollScheduler
  private var cancellables = Set<AnyCancellable>()
  private var isPolling = false

  public let manager: any PiholeServerManaging
  public let networkInterface: any LocalIPAddressProviding
  private let defaultsSuite: UserDefaults

  /// Owns the countdown pill (start/cancel on blocking changes) so every
  /// caller — menu actions and shortcuts — behaves identically. The status
  /// fetch also re-syncs it from the server's remaining time when idle.
  private let timerManager: TimerManager
  private let sleep: (TimeInterval) async throws -> Void
  /// Hard cap for a gravity trigger: URLSession's timeout is an idle timeout,
  /// so a slow-but-alive stream would otherwise hold the state indefinitely.
  private let gravityTriggerTimeout: TimeInterval
  /// FTL refreshes its cached `last_update` on a ~1s tick; wait this long
  /// before re-verifying a run whose timestamp hasn't moved.
  private static let gravityVerificationDelay: TimeInterval = 2

  /// How long the timer-end re-check keeps polling after the countdown ends
  /// before falling back to the scheduled poll cadence.
  private static let unblockRecheckAttempts = 6
  private static let unblockRecheckInterval: TimeInterval = 2

  /// Bumped by every manual `applyBlockingChange`; status fetches discard their
  /// results when it changes mid-request.
  private var blockingChangeGeneration = 0

  /// Fired when a poll observes blocking flip `.disabled` → `.enabled` without
  /// a manual action (manual toggles reflect locally and never trigger this).
  /// Fires once, when the last disabled server re-enables.
  public var onBlockingAutoReenabled: ((Set<UUID>) -> Void)?

  public init(
    manager: any PiholeServerManaging,
    networkInterface: any LocalIPAddressProviding,
    pollingInterval: TimeInterval = 30,
    defaultsSuite: UserDefaults = .standard,
    scheduler: any PollScheduler = TaskPollScheduler(),
    timerManager: TimerManager = TimerManager(),
    sleep: @escaping (TimeInterval) async throws -> Void = {
      try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
    },
    gravityTriggerTimeout: TimeInterval = 15 * 60
  ) {
    self.manager = manager
    self.networkInterface = networkInterface
    self.defaultsSuite = defaultsSuite
    self.pollingInterval = pollingInterval
    self.scheduler = scheduler
    self.timerManager = timerManager
    self.sleep = sleep
    self.gravityTriggerTimeout = gravityTriggerTimeout
    self.servers = manager.servers
    self.lastSuccessfulCheck = Dictionary(
      uniqueKeysWithValues: manager.servers.map { ($0.id, Date()) }
    )

    // Re-check blocking status when the countdown ends instead of waiting for the next poll.
    timerManager.onEnded = { [weak self] in
      guard let self else { return }
      Task { await self.refreshBlockingStatusesIfIdle() }
    }

    manager.serversPublisher
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] newServers in
        guard let self else { return }

        let structuralChange =
          newServers.count != self.servers.count
          || zip(self.servers, newServers).contains { $0.id != $1.id || $0.url != $1.url || $0.version != $1.version }

        let newIDs = Set(newServers.map(\.id))
        self.connectionStatuses = self.connectionStatuses.filter { newIDs.contains($0.key) }
        self.blockingStatuses = self.blockingStatuses.filter { newIDs.contains($0.key) }
        self.querySummaries = self.querySummaries.filter { newIDs.contains($0.key) }
        self.connectionStates = self.connectionStates.filter { newIDs.contains($0.key) }
        self.lastSuccessfulCheck = self.lastSuccessfulCheck.filter { newIDs.contains($0.key) }
        self.gravityCompletedAt = self.gravityCompletedAt.filter { newIDs.contains($0.key) }
        self.servers = newServers
        guard structuralChange, !self.isPolling else { return }
        Task { await self.performPoll() }
      }
      .store(in: &cancellables)
  }

  // MARK: - Polling Control

  public func startPolling() {
    guard !scheduler.isRunning else { return }
    startTicking()
  }

  public func stopPolling() {
    scheduler.stop()
  }

  public func pollNow() {
    startTicking()
  }

  private func startTicking() {
    scheduler.start(interval: pollingInterval) { [weak self] in
      await self?.performPoll()
    }
  }

  // MARK: - Blocking Operations

  /// Applies a blocking toggle to all servers and reflects the new state
  /// locally, so the menu dot doesn't wait for the next poll.
  ///
  /// The funnel for all blocking changes — prefer this over calling
  /// `manager.setBlocking(...)` directly. Also starts/cancels the countdown pill.
  /// - Returns: Per-server success/failure results (discardable).
  @discardableResult
  public func applyBlockingChange(enabled: Bool, duration: TimeInterval?) async -> [UUID: Bool] {
    // Invalidate any in-flight status fetch so a manual toggle can't be
    // misattributed as an automatic re-enable.
    blockingChangeGeneration += 1
    let results = await manager.setBlocking(enabled: enabled, duration: duration)
    for (id, success) in results {
      if success {
        let status: BlockingStatus = enabled ? .enabled : .disabled(remainingSeconds: duration)
        blockingStatuses[id] = status
        connectionStatuses[id] = .connected
        connectionStates[id] = .healthy
      } else {
        connectionStatuses[id] = .disconnected
        blockingStatuses.removeValue(forKey: id)
      }
    }

    // Countdown for time-boxed disables, cancel on re-enable.
    if enabled {
      timerManager.cancel()
    } else if let duration {
      timerManager.start(duration: duration)
    }

    return results
  }

  /// Triggers a gravity update on all v6 servers and verifies each server's
  /// gravity timestamp moved. The funnel for gravity updates — prefer this
  /// over calling `manager.updateGravity()` directly. Concurrent triggers are
  /// ignored while one is in flight.
  @discardableResult
  public func applyGravityUpdate() async -> [UUID: GravityUpdateOutcome] {
    guard !gravityOperationInFlight else { return [:] }
    gravityOperationInFlight = true
    defer { gravityOperationInFlight = false }

    let v6IDs = Set(manager.servers.filter { $0.version == .v6 }.map(\.id))
    guard !v6IDs.isEmpty else { return [:] }

    // Fresh before-snapshot: avoids relying on the last poll's data.
    let beforeSummaries = await manager.getQuerySummary()

    // Only the trigger phase drives the menu's "Updating gravity…".
    isGravityUpdating = true
    defer { isGravityUpdating = false }

    let results = await raceGravityTrigger(v6IDs: v6IDs, timeout: gravityTriggerTimeout)
    isGravityUpdating = false

    // Refresh summaries so the menu subtext is current on the next open.
    var afterSummaries = await manager.getQuerySummary()

    // FTL refreshes its cached `last_update` on a ~1s tick, so an immediate
    // after-fetch can race it and mistake a successful run for a no-change.
    // Re-check once after a short delay when movement isn't confirmed.
    if needsGravityRecheck(
      results: results,
      beforeSummaries: beforeSummaries,
      afterSummaries: afterSummaries
    ) {
      try? await sleep(Self.gravityVerificationDelay)
      let refreshed = await manager.getQuerySummary()
      for (id, summary) in refreshed {
        if let summary {
          afterSummaries[id] = summary
        }
      }
    }

    for (id, summary) in afterSummaries {
      if let summary {
        querySummaries[id] = summary
      } else {
        querySummaries.removeValue(forKey: id)
      }
    }

    return computeGravityOutcomes(
      results: results,
      beforeSummaries: beforeSummaries,
      afterSummaries: afterSummaries
    )
  }

  /// Maps each trigger result to an outcome, recording the app-observed
  /// completion time for verified successes.
  private func computeGravityOutcomes(
    results: [UUID: Result<Void, PiholeError>],
    beforeSummaries: [UUID: QuerySummary?],
    afterSummaries: [UUID: QuerySummary?]
  ) -> [UUID: GravityUpdateOutcome] {
    var outcomes: [UUID: GravityUpdateOutcome] = [:]
    for (id, result) in results {
      switch result {
      case .success:
        let beforeValue = beforeSummaries[id].flatMap { $0?.gravityLastUpdated }
        let afterValue = afterSummaries[id].flatMap { $0?.gravityLastUpdated }
        if beforeValue != afterValue {
          outcomes[id] = .succeeded
          gravityCompletedAt[id] = Date()
        } else {
          outcomes[id] = .noChange
        }
      case .failure(let error):
        outcomes[id] = .failed(error)
      }
    }
    return outcomes
  }

  /// Whether a successful trigger's timestamp movement still needs re-verifying.
  private func needsGravityRecheck(
    results: [UUID: Result<Void, PiholeError>],
    beforeSummaries: [UUID: QuerySummary?],
    afterSummaries: [UUID: QuerySummary?]
  ) -> Bool {
    results.contains { id, result in
      guard case .success = result else { return false }
      let before = beforeSummaries[id]?.flatMap { $0.gravityLastUpdated }
      let after = afterSummaries[id]?.flatMap { $0.gravityLastUpdated }
      return after == nil || after == before
    }
  }

  /// Runs the trigger against the watchdog; on timeout the client request is
  /// cancelled (the server-side run continues) and every v6 server fails.
  private func raceGravityTrigger(
    v6IDs: Set<UUID>,
    timeout: TimeInterval
  ) async -> [UUID: Result<Void, PiholeError>] {
    do {
      return try await withThrowingTaskGroup(of: [UUID: Result<Void, PiholeError>].self) { group in
        group.addTask { await self.runGravityTrigger() }
        group.addTask {
          try await self.sleepForGravityTimeout(timeout)
          throw PiholeError.unknown(
            "timed out after \(Int(timeout / 60)) minutes — check the Pi-hole web interface"
          )
        }
        guard let first = try await group.next() else {
          throw PiholeError.unknown("Gravity trigger produced no result")
        }
        group.cancelAll()
        return first
      }
    } catch {
      // Watchdog fired or the trigger was cancelled: report and move on.
      logger.warning("Gravity trigger aborted: \(error.localizedDescription, privacy: .public)")
      let piholeError = error as? PiholeError ?? PiholeError.unknown(error.localizedDescription)
      return Dictionary(uniqueKeysWithValues: v6IDs.map { ($0, .failure(piholeError)) })
    }
  }

  /// Runs `manager.updateGravity()` on the main actor so the non-Sendable
  /// manager never crosses into the `@Sendable` group child.
  private func runGravityTrigger() async -> [UUID: Result<Void, PiholeError>] {
    await manager.updateGravity()
  }

  /// Keeps the non-Sendable `sleep` out of the `@Sendable` watchdog task.
  private func sleepForGravityTimeout(_ timeout: TimeInterval) async throws {
    try await sleep(timeout)
  }

  /// Manual retry: one authoritative check for a single server, applied
  /// immediately (the same first-failure onset as polling). The result lets
  /// the UI relabel "Retry" → "Edit connection" on failure.
  public func refreshServer(id: UUID) async -> ServerConnectionState {
    guard !checkingServerIDs.contains(id) else {
      return connectionStates[id] ?? .unreachable(lastSeen: lastSuccessfulCheck[id])
    }
    checkingServerIDs.insert(id)
    defer { checkingServerIDs.remove(id) }

    guard let result = await manager.checkServer(id: id) else {
      return connectionStates[id] ?? .unreachable(lastSeen: lastSuccessfulCheck[id])
    }

    switch result {
    case .success(let status):
      lastSuccessfulCheck[id] = Date()
      connectionStates[id] = .healthy
      connectionStatuses[id] = .connected
      blockingStatuses[id] = status
      return .healthy
    case .failure(let error):
      let state: ServerConnectionState
      switch ServerCheckFailure.classify(error) {
      case .auth(let reason):
        state = .authError(reason: reason)
      case .unreachable:
        state = .unreachable(lastSeen: lastSuccessfulCheck[id])
      }
      connectionStates[id] = state
      connectionStatuses[id] = .disconnected
      blockingStatuses.removeValue(forKey: id)
      return state
    }
  }

  // MARK: - Polling Implementation

  private func performPoll() async {
    guard !isPolling else { return }
    isPolling = true
    defer { isPolling = false }
    guard !servers.isEmpty else {
      connectionStatuses = [:]
      blockingStatuses = [:]
      querySummaries = [:]
      recentBlocked = []
      lastPollError = nil
      connectionStates = [:]
      lastSuccessfulCheck = [:]
      return
    }

    logger.debug("Polling all servers...")
    await fetchBlockingStatuses()

    // Get query summaries from all servers in parallel
    let summaryResults = await manager.getQuerySummary()
    for (id, summary) in summaryResults {
      if let summary {
        querySummaries[id] = summary
      } else {
        querySummaries.removeValue(forKey: id)
      }
    }

    servers = manager.servers

    // Fetch recent blocked domains across all servers
    do {
      let clientIP = networkInterface.localIPAddress()
      let showAll = Defaults[.showAllClientsRecentBlocked(suite: defaultsSuite)]
      let interval = DateInterval(start: Date().addingTimeInterval(-3600), end: Date())
      let blocked = try await manager.getRecentBlocked(
        forClientIp: showAll ? nil : clientIP,
        interval: interval
      )
      recentBlocked = blocked
    } catch {
      logger.warning("Failed to refresh recent blocked: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Re-checks blocking status on countdown end; skips while a poll is in
  /// flight to avoid double-firing `onBlockingAutoReenabled`. The server's own
  /// timer can outlive the local countdown by a few seconds (timer resets,
  /// tick latency), so re-check briefly until it actually re-enables.
  private func refreshBlockingStatusesIfIdle() async {
    guard !isPolling else { return }
    isPolling = true
    defer { isPolling = false }
    logger.debug("Unblock countdown ended — re-checking blocking status")
    for attempt in 0..<Self.unblockRecheckAttempts {
      await fetchBlockingStatuses()
      if !hasDisabledServers() { return }
      if attempt < Self.unblockRecheckAttempts - 1 {
        try? await sleep(Self.unblockRecheckInterval)
      }
    }
  }

  private func hasDisabledServers() -> Bool {
    blockingStatuses.values.contains { status in
      if case .disabled = status { return true }
      return false
    }
  }

  /// Fetches blocking status for all servers, firing `onBlockingAutoReenabled`
  /// on a poll-observed disabled→enabled transition.
  private func fetchBlockingStatuses() async {
    let generation = blockingChangeGeneration
    // Snapshot pre-poll state to detect servers that re-enabled on their own.
    let previouslyDisabledIDs = Set(
      blockingStatuses.compactMap { id, status in
        if case .disabled = status { return id }
        return nil
      })
    let blockingResults = await manager.getBlockingStatus()
    // A manual toggle landed mid-fetch: its local reflection is authoritative,
    // and applying the stale results could misreport a manual re-enable as an
    // automatic one.
    guard generation == blockingChangeGeneration else { return }
    for (id, result) in blockingResults {
      switch result {
      case .success(let status):
        lastSuccessfulCheck[id] = Date()
        connectionStates[id] = .healthy
        blockingStatuses[id] = status
      case .failure(let error):
        // First failure flips the row immediately with its classification.
        // Keep the stronger signal: never downgrade a confirmed authError to
        // unreachable over transient network failures — the re-auth affordance
        // must not silently disappear. A success resets the row.
        if case .authError = connectionStates[id],
          ServerCheckFailure.classify(error) == .unreachable
        {
          continue
        }
        switch ServerCheckFailure.classify(error) {
        case .auth(let reason):
          connectionStates[id] = .authError(reason: reason)
        case .unreachable:
          connectionStates[id] = .unreachable(lastSeen: lastSuccessfulCheck[id])
        }
        blockingStatuses.removeValue(forKey: id)
      }
    }
    syncConnectionStatusesFromStates()
    notifyIfAutoReenabled(previousDisabledIDs: previouslyDisabledIDs)
    syncCountdownWithServerRemaining()
  }

  /// Derives the menu's `connectionStatuses` from the row state. Only touches
  /// ids that already have a row state — pre-poll behavior is unchanged.
  private func syncConnectionStatusesFromStates() {
    for (id, state) in connectionStates {
      switch state {
      case .healthy:
        connectionStatuses[id] = .connected
      case .authError, .unreachable:
        connectionStatuses[id] = .disconnected
      }
    }
  }

  /// Keeps the countdown pill and the timer-end re-check tracking the server's
  /// actual timer: when no local countdown is running but a server reports a
  /// time-boxed disable, run the countdown from its remaining time. Covers
  /// disables initiated outside the app, relaunches mid-unblock, and server
  /// timer resets.
  private func syncCountdownWithServerRemaining() {
    guard !timerManager.isRunning else { return }
    var remaining: TimeInterval = 0
    for status in blockingStatuses.values {
      if case .disabled(let seconds) = status, let seconds {
        remaining = max(remaining, seconds)
      }
    }
    guard remaining > 5 else { return }
    timerManager.start(duration: remaining)
  }

  /// Fires `onBlockingAutoReenabled` once the last disabled server re-enables
  /// via poll. Manual re-enables never reach this path.
  private func notifyIfAutoReenabled(previousDisabledIDs: Set<UUID>) {
    guard !previousDisabledIDs.isEmpty else { return }
    let autoReenabled = previousDisabledIDs.filter { blockingStatuses[$0] == .enabled }
    let anyStillDisabled = blockingStatuses.values.contains { status in
      if case .disabled = status { return true }
      return false
    }
    if !autoReenabled.isEmpty, !anyStillDisabled {
      onBlockingAutoReenabled?(autoReenabled)
      // The unblock has ended — drop any re-armed countdown so the pill
      // doesn't outlive the transition.
      timerManager.cancel()
    }
  }
}
