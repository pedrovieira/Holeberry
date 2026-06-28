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

  let manager: PiholeServerManager

  init(manager: PiholeServerManager) {
    self.manager = manager
    self.servers = manager.servers
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

  func addServer(label: String?, url: String, credential: String) async throws {
    try await manager.addServer(label: label, url: url, credential: credential)
    servers = manager.servers
    await pollNow()
  }

  func updateServer(id: UUID, label: String?, url: String, credential: String?) async {
    manager.updateServer(id: id, label: label, url: url, credential: credential)
    servers = manager.servers
    connectionStatuses.removeValue(forKey: id)
    blockingStatuses.removeValue(forKey: id)
    await pollNow()
  }

  func deleteServer(id: UUID) {
    manager.deleteServer(id: id)
    servers = manager.servers
    connectionStatuses.removeValue(forKey: id)
    blockingStatuses.removeValue(forKey: id)
    combinedStatus.totalInstanceCount = servers.count
    combinedStatus.connectedInstanceCount = connectionStatuses.values.filter { $0 == .connected }.count
  }

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

  // MARK: - Blocking Controls

  func setBlocking(for id: UUID, enabled: Bool, duration: TimeInterval?) async throws {
    try await manager.setBlocking(for: id, enabled: enabled, duration: duration)
  }

  // MARK: - On-Demand Fetching

  func fetchRecentBlocked(for id: UUID) async throws -> [String] {
    let length = max(Defaults[.recentBlockedCount], 20)
    return try await manager.perform(for: id) { service in
      try await service.getRecentBlocked(count: length)
    }
  }

  // MARK: - Polling Implementation

  private func performPoll() async {
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
      guard let credential = try? KeychainManager.shared.readCredential(for: config.id) else {
        connectionStatuses[config.id] = .disconnected
        blockingStatuses.removeValue(forKey: config.id)
        anyError = anyError ?? "Missing credentials for \(config.label ?? config.url)"
        continue
      }

      do {
        let version = try await manager.testConnection(url: config.url, credential: credential)
        manager.updateServerVersion(id: config.id, version: version)

        let blocking = try await manager.getBlockingStatus(for: config.id)
        connectionStatuses[config.id] = .connected
        blockingStatuses[config.id] = blocking
        connectedCount += 1

        // Aggregate query summary stats
        do {
          let summary = try await manager.perform(for: config.id) { service in
            try await service.getQuerySummary()
          }
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
