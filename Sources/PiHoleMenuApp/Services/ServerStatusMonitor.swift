import Defaults
import Foundation
import OSLog

@MainActor
final class ServerStatusMonitor: ObservableObject {
  static let shared = ServerStatusMonitor(manager: PiholeServerManager())

  @Published var servers: [PiholeServer] = []
  @Published var connectionStatuses: [UUID: ConnectionStatus] = [:]
  @Published var blockingStatuses: [UUID: BlockingStatus] = [:]
  @Published var combinedStatus = CombinedStatus()
  @Published var lastPollError: String?

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

  // MARK: - Blocking Controls

  func setBlocking(for server: PiholeServer, enabled: Bool, duration: TimeInterval?) async throws {
    try await manager.setBlocking(for: server, enabled: enabled, duration: duration)
  }

  // MARK: - On-Demand Fetching

  func fetchRecentBlocked(for server: PiholeServer) async throws -> [String] {
    let length = max(Defaults[.recentBlockedCount], 20)
    return try await manager.perform(for: server) { service in
      try await service.getRecentBlocked(count: length)
    }
  }

  // MARK: - Polling Implementation

  private func performPoll() async {
    logger.debug("Polling all servers...")
    var connectedCount = 0
    var anyError: String?

    for server in servers {
      guard let credential = try? KeychainManager.shared.readCredential(for: server.id) else {
        connectionStatuses[server.id] = .disconnected
        blockingStatuses.removeValue(forKey: server.id)
        anyError = anyError ?? "Missing credentials for \(server.label ?? server.url)"
        continue
      }

      do {
        if server.version == nil {
          let version = try await manager.testConnection(url: server.url, credential: credential)
          manager.updateServerVersion(id: server.id, version: version)
        }

        let blocking = try await manager.getBlockingStatus(for: server)
        connectionStatuses[server.id] = .connected
        blockingStatuses[server.id] = blocking
        connectedCount += 1
      } catch {
        logger.warning("Poll failed for \(server.label ?? server.url): \(error.localizedDescription, privacy: .public)")
        connectionStatuses[server.id] = .disconnected
        blockingStatuses.removeValue(forKey: server.id)
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
  }
}
