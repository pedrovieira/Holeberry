import Defaults
import Foundation
import OSLog

@MainActor
final class TempUnblockManager {
  static let shared = TempUnblockManager(serverProvider: PiholeServerManager.shared)

  @Published var activeRecords: [TempUnblockRecord] = []

  private let serverProvider: ServerProviding
  private var expiryTasks: [String: Task<Void, Never>] = [:]
  private var retryTasks: [String: Task<Void, Never>] = [:]
  private let backoffIntervals: [TimeInterval]
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "temp-unblock")

  init(
    serverProvider: ServerProviding,
    backoffIntervals: [TimeInterval] = [10, 30, 120, 600]
  ) {
    self.serverProvider = serverProvider
    self.backoffIntervals = backoffIntervals
    self.activeRecords = restoreFromDefaults()
  }

  func add(domain: String, duration: TimeInterval) async throws -> TempUnblockRecord {
    if let existing = activeRecords.first(where: { $0.domain == domain }) {
      logger.info("Domain already unblocked: \(domain, privacy: .public)")
      return existing
    }

    guard !serverProvider.servers.isEmpty else {
      throw PiholeError.unknown("No configured Pi-hole instance")
    }

    let uuid = "holeberry:\(UUID().uuidString)"
    var anySuccess = false
    var lastError: Error?

    for config in serverProvider.servers {
      do {
        try await serverProvider.perform(for: config.id) { service in
          _ = try await service.addDomain(domain, to: .allow, comment: uuid)
        }
        anySuccess = true
      } catch {
        lastError = error
        logger.warning(
          """
          Failed to add unblock on \(config.label ?? config.url, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """)
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

  func restoreFromDefaults() -> [TempUnblockRecord] {
    Defaults[.tempUnblocks]
  }

  func saveRecords() {
    Defaults[.tempUnblocks] = activeRecords
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

    let configs = serverProvider.servers
    var anyFailure = false

    for config in configs {
      do {
        try await serverProvider.perform(for: config.id) { service in
          try await service.deleteDomain(domain: record.domain)
        }
      } catch PiholeError.unknown {
        continue
      } catch {
        anyFailure = true
        logger.warning(
          """
          Expiry cleanup failed for \(record.domain, privacy: .public) on \
          \(config.label ?? config.url, privacy: .public): \(error.localizedDescription, privacy: .public)
          """)
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

    let configs = serverProvider.servers
    var anyFailure = false

    for config in configs {
      do {
        try await serverProvider.perform(for: config.id) { service in
          try await service.deleteDomain(domain: record.domain)
        }
      } catch PiholeError.unknown {
        continue
      } catch {
        anyFailure = true
        logger.warning(
          """
          Retry removal failed for \(record.domain, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """)
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

  // MARK: - Reconcile

  func reconcileOnLaunch() async {
    var recordsToRemove: [String] = []
    let now = Date()

    for record in activeRecords {
      // Expired records: attempt Pi-hole deletion, mark pendingRemoval with retry on failure
      if record.startDateUTC.addingTimeInterval(record.durationSeconds) <= now {
        await removeExpired(uuid: record.uuid)
        continue
      }

      // Active records: cross-reference against Pi-hole allowlist
      if await !isPresentOnAnyServer(record) {
        recordsToRemove.append(record.uuid)
      } else {
        startExpiryTask(for: record)
      }
    }

    for uuid in recordsToRemove {
      expiryTasks.removeValue(forKey: uuid)
      retryTasks.removeValue(forKey: uuid)
      activeRecords.removeAll { $0.uuid == uuid }
    }
    if !recordsToRemove.isEmpty {
      saveRecords()
    }
  }

  private func isPresentOnAnyServer(_ record: TempUnblockRecord) async -> Bool {
    for config in serverProvider.servers {
      do {
        let domains: [DomainEntry] = try await serverProvider.perform(for: config.id) { service in
          try await service.getDomains()
        }
        let found = domains.contains { entry in
          if config.version == .v6 {
            return entry.comment?.contains(record.uuid) ?? false
          }
          return entry.domain == record.domain
        }
        if found { return true }
      } catch {
        logger.warning(
          """
          Reconcile getDomains failed for \(config.label ?? config.url, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """)
        continue
      }
    }
    return false
  }
}
