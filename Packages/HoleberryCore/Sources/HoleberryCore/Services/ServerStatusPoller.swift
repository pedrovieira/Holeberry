import Combine
import Defaults
import Foundation
import OSLog

@MainActor
public final class ServerStatusPoller: ObservableObject {
  // MARK: - Published state

  @Published public var servers: [ServerConfig] = []
  @Published public var connectionStatuses: [UUID: ConnectionStatus] = [:]
  @Published public var blockingStatuses: [UUID: BlockingStatus] = [:]
  @Published public var querySummaries: [UUID: QuerySummary] = [:]
  @Published public var lastPollError: String?
  @Published public var recentBlocked: [BlockedDomain] = []
  @Published public var connectionStates: [UUID: ServerConnectionState] = [:]
  @Published public var checkingServerIDs: Set<UUID> = []

  /// Fired when a poll observes blocking flip `.disabled` → `.enabled` without
  /// a manual action (manual toggles reflect locally and never trigger this).
  /// Fires once, when the last disabled server re-enables.
  public var onBlockingRestoredAutomatically: ((Set<UUID>) -> Void)?

  /// True while the gravity trigger phase runs.
  public var isGravityUpdating: Bool { gravityUpdater.isUpdating }

  /// App-observed gravity completion times, clamped into the menu's
  /// staleness subtext (see `GravityUpdating.completedAt`).
  public var gravityCompletedAt: [UUID: Date] { gravityUpdater.completedAt }

  // MARK: - Injected dependencies

  public let manager: any PiholeServerManaging
  public let networkInterface: any LocalIPAddressProviding
  private let defaultsSuite: UserDefaults
  /// Owns the gravity update state machine (trigger/verify/watchdog) and the
  /// app-observed completion times; delegating keeps blocking/polling logic
  /// separate and makes the gravity path testable in isolation.
  private let gravityUpdater: any GravityUpdating
  /// Owns the countdown pill (start/cancel on blocking changes) so every
  /// caller — menu actions and shortcuts — behaves identically. The status
  /// fetch also re-syncs it from the server's remaining time when idle.
  private let timerManager: TimerManager
  private let scheduler: any PollScheduler
  private let pollingInterval: TimeInterval
  private let sleep: (TimeInterval) async throws -> Void
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "status-monitor")

  // MARK: - Private state

  private var lastSuccessfulCheck: [UUID: Date] = [:]
  /// Bumped by every manual `applyBlockingChange`; status fetches discard their
  /// results when it changes mid-request.
  private var blockingChangeGeneration = 0
  private var cancellables = Set<AnyCancellable>()
  private var isPolling = false

  /// How long the timer-end re-check keeps polling after the countdown ends
  /// before falling back to the scheduled poll cadence.
  private static let unblockRecheckAttempts = 6
  private static let unblockRecheckInterval: TimeInterval = 2

  public init(
    manager: any PiholeServerManaging,
    networkInterface: any LocalIPAddressProviding,
    pollingInterval: TimeInterval,
    defaultsSuite: UserDefaults = .standard,
    scheduler: any PollScheduler,
    timerManager: TimerManager,
    gravityUpdater: any GravityUpdating,
    sleep: @escaping (TimeInterval) async throws -> Void = {
      try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
    }
  ) {
    self.manager = manager
    self.networkInterface = networkInterface
    self.defaultsSuite = defaultsSuite
    self.pollingInterval = pollingInterval
    self.scheduler = scheduler
    self.timerManager = timerManager
    self.sleep = sleep
    self.gravityUpdater = gravityUpdater
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
        self.gravityUpdater.prune(keeping: newIDs)
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

  /// Triggers a gravity update on all servers via the injected
  /// `gravityUpdater` and reports per-server outcomes. The funnel for gravity
  /// updates — prefer this over calling `manager.updateGravity()` directly.
  @discardableResult
  public func applyGravityUpdate() async -> [UUID: GravityUpdateOutcome] {
    await gravityUpdater.applyUpdate()
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
      switch ServerCheckFailure.classify(error) {
      case .auth(let reason):
        let state = ServerConnectionState.authError(reason: reason)
        connectionStates[id] = state
        connectionStatuses[id] = .disconnected
        blockingStatuses.removeValue(forKey: id)
        return state
      case .unreachable:
        let state = ServerConnectionState.unreachable(lastSeen: lastSuccessfulCheck[id])
        connectionStates[id] = state
        connectionStatuses[id] = .disconnected
        blockingStatuses.removeValue(forKey: id)
        return state
      case .unsupported:
        // The server responded, it just can't do the requested operation —
        // not an auth or connectivity failure, so leave the row as-is.
        return connectionStates[id] ?? .unreachable(lastSeen: lastSuccessfulCheck[id])
      }
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
  /// flight to avoid double-firing `onBlockingRestoredAutomatically`. The server's own
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

  /// Fetches blocking status for all servers, firing `onBlockingRestoredAutomatically`
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
        case .unsupported:
          // Server responded but can't do the operation — not a connectivity
          // or auth failure, so leave the row as-is.
          continue
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

  /// Fires `onBlockingRestoredAutomatically` once the last disabled server re-enables
  /// via poll. Manual re-enables never reach this path.
  private func notifyIfAutoReenabled(previousDisabledIDs: Set<UUID>) {
    guard !previousDisabledIDs.isEmpty else { return }
    let autoReenabled = previousDisabledIDs.filter { blockingStatuses[$0] == .enabled }
    let anyStillDisabled = blockingStatuses.values.contains { status in
      if case .disabled = status { return true }
      return false
    }
    if !autoReenabled.isEmpty, !anyStillDisabled {
      onBlockingRestoredAutomatically?(autoReenabled)
      // The unblock has ended — drop any re-armed countdown so the pill
      // doesn't outlive the transition.
      timerManager.cancel()
    }
  }
}
