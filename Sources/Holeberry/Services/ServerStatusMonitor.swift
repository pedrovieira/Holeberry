import Combine
import Defaults
import Foundation
import OSLog

@MainActor
final class ServerStatusMonitor: ObservableObject {
  static let shared = ServerStatusMonitor(manager: .shared)

  @Published var servers: [ServerConfig] = []
  @Published var connectionStatuses: [UUID: ConnectionStatus] = [:]
  @Published var blockingStatuses: [UUID: BlockingStatus] = [:]
  @Published var combinedStatus = CombinedStatus()
  @Published var lastPollError: String?

  // Scanner state (persists across tab switches)
  @Published var discoveredInstances: [PiHoleScanner.DiscoveredInstance] = []
  @Published var isScanning = false

  private let logger = Logger(subsystem: Logger.appSubsystem, category: "status-monitor")
  private var pollingTask: Task<Void, Never>?
  private var cancellables = Set<AnyCancellable>()
  private var isPolling = false

  let manager: PiholeServerManager

  init(manager: PiholeServerManager) {
    self.manager = manager
    self.servers = manager.servers

    manager.$servers
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
        self.servers = newServers
        self.combinedStatus.totalInstanceCount = newServers.count
        self.combinedStatus.connectedInstanceCount = self.connectionStatuses.values.filter { $0 == .connected }.count
        guard structuralChange, !self.isPolling else { return }
        Task { await self.pollNow() }
      }
      .store(in: &cancellables)
  }

  // MARK: - Polling Control

  func startPolling(interval: TimeInterval = 30) {
    guard pollingTask == nil else {
      logger.info("Polling already running, ignoring duplicate start")
      return
    }
    pollingTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        await self.performPoll()
        try? await Task.sleep(for: .seconds(interval))
      }
    }
  }

  func stopPolling() {
    guard pollingTask != nil else {
      logger.info("Polling already stopped, ignoring duplicate stop")
      return
    }
    pollingTask?.cancel()
    pollingTask = nil
  }

  func pollNow() async {
    await performPoll()
  }

  // MARK: - Server CRUD

  func logoutAll() async {
    await manager.logoutAll()
  }

  // MARK: - Scanning

  private var connectedCount: Int {
    connectionStatuses.values.filter { $0 == .connected }.count
  }

  func runScanIfNeeded() async {
    guard connectedCount < 2 else {
      discoveredInstances = []
      isScanning = false
      return
    }

    isScanning = true
    discoveredInstances = await PiHoleScanner.scan()
    isScanning = false
  }

  // MARK: - Polling Implementation

  private func performPoll() async {
    isPolling = true
    defer { isPolling = false }
    guard !servers.isEmpty else {
      connectionStatuses = [:]
      blockingStatuses = [:]
      combinedStatus = CombinedStatus()
      lastPollError = nil
      return
    }

    logger.debug("Polling all servers...")
    var connectedCount = 0
    var totalQueries = 0
    var totalBlocked = 0
    var anyError: String?

    for config in servers {
      do {
        let blocking = try await manager.getBlockingStatus(for: config.id)
        connectionStatuses[config.id] = .connected
        blockingStatuses[config.id] = blocking
        connectedCount += 1

        // Aggregate query summary stats
        do {
          let summary = try await manager.getQuerySummary(for: config.id)
          totalQueries += summary.totalQueries
          totalBlocked += summary.totalBlocked
        } catch {
          logger.warning(
            "Query summary failed for \(config.label ?? config.url): \(error.localizedDescription, privacy: .public)")
          // Non-fatal: stats just won't include this instance this cycle
        }
      } catch {
        logger.warning("Poll failed for \(config.label ?? config.url): \(error.localizedDescription, privacy: .public)")
        connectionStatuses[config.id] = .disconnected
        blockingStatuses.removeValue(forKey: config.id)
        anyError = anyError ?? error.localizedDescription
      }
    }

    servers = manager.servers

    combinedStatus.connectedInstanceCount = connectedCount
    combinedStatus.totalInstanceCount = servers.count
    combinedStatus.blockingEnabled =
      !servers.isEmpty
      && blockingStatuses.values.allSatisfy { status in
        if case .enabled = status { return true }
        return false
      }
    lastPollError = anyError

    combinedStatus.totalQueries = totalQueries
    combinedStatus.totalBlocked = totalBlocked
  }
}
