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

  public init(
    manager: any PiholeServerManaging,
    networkInterface: any LocalIPAddressProviding,
    pollingInterval: TimeInterval = 30,
    defaultsSuite: UserDefaults = .standard,
    scheduler: any PollScheduler = TaskPollScheduler()
  ) {
    self.manager = manager
    self.networkInterface = networkInterface
    self.defaultsSuite = defaultsSuite
    self.pollingInterval = pollingInterval
    self.scheduler = scheduler
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

  /// Send a blocking toggle to the server and immediately reflect the new state locally,
  /// so the menu dot doesn't wait 30s for the next poll to update.
  ///
  /// - Note: This is the funnel that keeps `blockingStatuses` and `connectionStatuses`
  ///   in sync. Prefer this over calling `manager.setBlocking(...)` directly, which
  ///   bypasses the local reflection.
  /// Send a blocking toggle to all servers and immediately reflect the new state locally.
  public func applyBlockingChange(enabled: Bool, duration: TimeInterval?) async {
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

    // Get blocking statuses from all servers in parallel
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
}
