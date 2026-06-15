import Foundation
import OSLog

@MainActor
final class TempUnblockManager {
  static let shared = TempUnblockManager(serverProvider: PiholeServerManager())

  @Published private(set) var activeRecords: [TempUnblockRecord] = []

  private let serverProvider: ServerProviding
  private var expiryTasks: [String: Task<Void, Never>] = [:]
  private var retryTasks: [String: Task<Void, Never>] = [:]
  private let backoffIntervals: [TimeInterval]
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "temp-unblock")
  private let defaults: UserDefaults
  private let storageKey = "tempUnblocks"

  init(
    serverProvider: ServerProviding,
    backoffIntervals: [TimeInterval] = [10, 30, 120, 600],
    userDefaults: UserDefaults = .standard
  ) {
    self.serverProvider = serverProvider
    self.backoffIntervals = backoffIntervals
    self.defaults = userDefaults
    self.activeRecords = restoreFromUserDefaults()
  }

  func add(domain: String, duration: TimeInterval) async throws -> TempUnblockRecord {
    if let existing = activeRecords.first(where: { $0.domain == domain }) {
      logger.info("Domain already unblocked: \(domain, privacy: .public)")
      return existing
    }

    guard !serverProvider.servers.isEmpty else {
      throw PiholeError.unknown("No configured Pi-hole instance")
    }

    let uuid = "pihole-menu-app:\(UUID().uuidString)"
    var anySuccess = false
    var lastError: Error?

    for server in serverProvider.servers where server.version != nil {
      do {
        try await serverProvider.perform(for: server) { service in
          _ = try await service.addDomain(domain, to: .allow, comment: uuid)
        }
        anySuccess = true
      } catch {
        lastError = error
        logger.warning("Failed to add unblock on \(server.label ?? server.url): \(error.localizedDescription, privacy: .public)")
      }
    }

    guard anySuccess else {
      throw lastError ?? PiholeError.unknown("Failed to unblock domain on all servers")
    }

    let record = TempUnblockRecord(
      domain: domain,
      uuid: uuid,
      startDateUTC: Date(),
      durationSeconds: duration
    )

    activeRecords.append(record)
    saveRecords()
    startExpiryTask(for: record)
    return record
  }

  // MARK: - Persistence

  func restoreFromUserDefaults() -> [TempUnblockRecord] {
    guard let data = defaults.data(forKey: storageKey) else { return [] }
    guard let records = try? JSONDecoder().decode([TempUnblockRecord].self, from: data) else {
      logger.warning("Failed to decode temp unblock records")
      return []
    }
    return records.filter { $0.startDateUTC.addingTimeInterval($0.durationSeconds) > Date() }
  }

  func saveRecords() {
    do {
      let data = try JSONEncoder().encode(activeRecords)
      defaults.set(data, forKey: storageKey)
    } catch {
      logger.error("Failed to save temp unblock records: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - Expiry

  private func startExpiryTask(for record: TempUnblockRecord) {
    expiryTasks[record.uuid] = Task { [weak self] in
      try? await Task.sleep(for: .seconds(record.durationSeconds))
      await self?.removeExpired(uuid: record.uuid)
    }
  }

  private func removeExpired(uuid: String) async {
    guard let record = activeRecords.first(where: { $0.uuid == uuid }) else { return }

    let servers = serverProvider.servers.filter { $0.version != nil }
    var anyFailure = false

    for server in servers {
      do {
        try await serverProvider.perform(for: server) { service in
          try await service.deleteDomain(domain: record.domain)
        }
      } catch PiholeError.unknown {
        continue
      } catch {
        anyFailure = true
        logger.warning("Expiry cleanup failed for \(record.domain, privacy: .public) on \(server.label ?? server.url): \(error.localizedDescription, privacy: .public)")
      }
    }

    if anyFailure {
      if let idx = activeRecords.firstIndex(where: { $0.uuid == uuid }) {
        activeRecords[idx].pendingRemoval = true
        activeRecords[idx].retryCount += 1
        saveRecords()
        scheduleRetry(uuid: uuid)
      }
    } else {
      expiryTasks.removeValue(forKey: uuid)
      retryTasks.removeValue(forKey: uuid)
      activeRecords.removeAll { $0.uuid == uuid }
      saveRecords()
    }
  }

  private func scheduleRetry(uuid: String) {
    retryTasks[uuid] = Task { [weak self] in
      guard let self else { return }
      let retryCount = self.activeRecords.first { $0.uuid == uuid }?.retryCount ?? 0
      let backoff = self.backoffIntervals[
        min(retryCount, self.backoffIntervals.count - 1)
      ]
      try? await Task.sleep(for: .seconds(backoff))
      await self.retryRemoval(uuid: uuid)
    }
  }

  private func retryRemoval(uuid: String) async {
    guard
      let record = activeRecords.first(where: { $0.uuid == uuid }),
      record.pendingRemoval
    else { return }

    let servers = serverProvider.servers.filter { $0.version != nil }
    var anyFailure = false

    for server in servers {
      do {
        try await serverProvider.perform(for: server) { service in
          try await service.deleteDomain(domain: record.domain)
        }
      } catch PiholeError.unknown {
        continue
      } catch {
        anyFailure = true
        logger.warning("Retry removal failed for \(record.domain, privacy: .public): \(error.localizedDescription, privacy: .public)")
      }
    }

    if anyFailure {
      if let idx = activeRecords.firstIndex(where: { $0.uuid == uuid }) {
        activeRecords[idx].retryCount += 1
        saveRecords()
        scheduleRetry(uuid: uuid)
      }
    } else {
      retryTasks.removeValue(forKey: uuid)
      expiryTasks.removeValue(forKey: uuid)
      activeRecords.removeAll { $0.uuid == uuid }
      saveRecords()
    }
  }
}
