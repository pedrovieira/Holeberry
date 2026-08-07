import Combine
import Defaults
import Foundation
import OSLog

@MainActor
public final class ServerStatusPoller: ObservableObject {
  @Published public var servers: [ServerConfig] = []
  @Published public var connectionStatuses: [UUID: ConnectionStatus] = [:]
  @Published public var blockingStatuses: [UUID: BlockingStatus] = [:]
  @Published public var querySummaries: [UUID: QuerySummary] = [:]
  @Published public var lastPollError: String?
  @Published public var recentBlocked: [BlockedDomain] = []

  private let logger = Logger(subsystem: Logger.appSubsystem, category: "status-monitor")
  private let pollingInterval: TimeInterval
  private let scheduler: any PollScheduler
  private var cancellables = Set<AnyCancellable>()
  private var isPolling = false

  public let manager: any PiholeServerManaging
  public let networkInterface: any LocalIPAddressProviding
  private let defaultsSuite: UserDefaults

  /// Owns the countdown pill (start/cancel on blocking changes) so every
  /// caller — menu actions and shortcuts — behaves identically.
  private let timerManager: TimerManager

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
    timerManager: TimerManager = TimerManager()
  ) {
    self.manager = manager
    self.networkInterface = networkInterface
    self.defaultsSuite = defaultsSuite
    self.pollingInterval = pollingInterval
    self.scheduler = scheduler
    self.timerManager = timerManager
    self.servers = manager.servers

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
    let results = await manager.setBlocking(enabled: enabled, duration: duration)
    for (id, success) in results {
      if success {
        let status: BlockingStatus = enabled ? .enabled : .disabled(remainingSeconds: duration)
        blockingStatuses[id] = status
        connectionStatuses[id] = .connected
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


  // MARK: - Polling Implementation

  private func performPoll() async {
    isPolling = true
    defer { isPolling = false }
    guard !servers.isEmpty else {
      connectionStatuses = [:]
      blockingStatuses = [:]
      querySummaries = [:]
      recentBlocked = []
      lastPollError = nil
      return
    }

    logger.debug("Polling all servers...")

    // Snapshot pre-poll state to detect servers that re-enabled on their own.
    let previouslyDisabledIDs = Set(
      blockingStatuses.compactMap { id, status in
        if case .disabled = status { return id }
        return nil
      })
    let blockingResults = await manager.getBlockingStatus()
    for (id, status) in blockingResults {
      if let status {
        connectionStatuses[id] = .connected
        blockingStatuses[id] = status
      } else {
        connectionStatuses[id] = .disconnected
        blockingStatuses.removeValue(forKey: id)
      }
    }
    notifyIfAutoReenabled(previousDisabledIDs: previouslyDisabledIDs)

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
    }
  }
}
