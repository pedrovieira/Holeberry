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
    // Will be implemented in Task 4
  }
}
