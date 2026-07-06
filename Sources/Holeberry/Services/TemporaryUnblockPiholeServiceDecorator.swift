import Defaults
import Foundation
import OSLog

@MainActor
final class TemporaryUnblockPiholeServiceDecorator: PiholeServiceInternal {
  private let wrapped: PiholeServiceInternal

  // Identity — delegates to wrapped
  var id: UUID { wrapped.id }
  var label: String? {
    get { wrapped.label }
    set { wrapped.label = newValue }
  }
  var url: String {
    get { wrapped.url }
    set { wrapped.url = newValue }
  }
  var version: ServerVersion {
    get { wrapped.version }
    set { wrapped.version = newValue }
  }

  // Unblock state — per-server
  private var activeRecords: [TempUnblockRecord] = []
  private var expiryTasks: [String: Task<Void, Never>] = [:]
  private var retryTasks: [String: Task<Void, Never>] = [:]
  private let backoffIntervals: [TimeInterval]
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "temp-unblock")

  init(
    service: PiholeServiceInternal,
    backoffIntervals: [TimeInterval] = [10, 30, 120, 600]
  ) {
    self.wrapped = service
    self.backoffIntervals = backoffIntervals
    self.activeRecords = restoreFromDefaults()
    if !activeRecords.isEmpty {
      Task { await reconcileWithServer() }
    }
  }

  // MARK: - Passthrough methods

  func addDomain(_ domain: String, to list: DomainListType) async throws -> DomainEntry {
    try await wrapped.addDomain(domain, to: list, comment: nil)
  }

  func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainEntry {
    try await wrapped.addDomain(domain, to: list, comment: comment)
  }

  func deleteDomain(domain: String) async throws {
    try await wrapped.deleteDomain(domain: domain)
    activeRecords.removeAll { $0.domain == domain }
    saveRecords()
  }

  func deleteDomain(identifiedBy id: Int) async throws {
    try await wrapped.deleteDomain(identifiedBy: id)
  }

  func checkStatus() async throws -> BlockingStatus {
    try await wrapped.checkStatus()
  }

  func getQuerySummary() async throws -> QuerySummary {
    try await wrapped.getQuerySummary()
  }

  func setBlocking(enabled: Bool, duration: TimeInterval?) async throws {
    try await wrapped.setBlocking(enabled: enabled, duration: duration)
  }

  func getRecentBlocked(count: Int) async throws -> [String] {
    try await wrapped.getRecentBlocked(count: count)
  }

  func getRecentQueries(clientIP: String?) async throws -> [RecentQuery] {
    try await wrapped.getRecentQueries(clientIP: clientIP)
  }

  func getDomains() async throws -> [DomainEntry] {
    try await wrapped.getDomains()
  }

  func logout() async {
    await wrapped.logout()
  }

  func login() async throws {
    try await wrapped.login()
  }

  // MARK: - Unblock

  func unblockDomain(_ domain: String, duration: TimeInterval?) async throws {
    if let duration {
      let uuid = "holeberry:\(UUID().uuidString)"
      _ = try await wrapped.addDomain(domain, to: .allow, comment: uuid)
      let record = TempUnblockRecord(
        domain: domain,
        uuid: uuid,
        startDateUTC: Date(),
        durationSeconds: duration
      )
      activeRecords.append(record)
      saveRecords()
      startExpiryTask(for: record)
    } else {
      _ = try await wrapped.addDomain(domain, to: .allow, comment: nil)
    }
  }

  // MARK: - Persistence

  private func restoreFromDefaults() -> [TempUnblockRecord] {
    Defaults[.tempUnblocks(for: wrapped.id)]
  }

  private func saveRecords() {
    Defaults[.tempUnblocks(for: wrapped.id)] = activeRecords
  }

  // MARK: - Init-time reconciliation

  /// Reconciliation task captures the records at init time and only processes those.
  private func reconcileWithServer() async {
    let initialRecords = activeRecords
    guard !initialRecords.isEmpty else { return }

    guard let domains = try? await wrapped.getDomains() else {
      for record in initialRecords where !record.pendingRemoval {
        startExpiryTask(for: record)
      }
      return
    }
    let serverDomains = Set(domains.compactMap { $0.domain })
    activeRecords = activeRecords.filter { record in
      // Only remove records that were present at init time and are not on the server
      guard initialRecords.contains(where: { $0.uuid == record.uuid }) else { return true }
      return serverDomains.contains(record.domain)
    }
    saveRecords()
    for record in activeRecords where !record.pendingRemoval {
      startExpiryTask(for: record)
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

    do {
      try await wrapped.deleteDomain(domain: record.domain)
      expiryTasks.removeValue(forKey: uuid)
      retryTasks.removeValue(forKey: uuid)
      activeRecords.removeAll { $0.uuid == uuid }
      saveRecords()
    } catch PiholeError.unknown {
      expiryTasks.removeValue(forKey: uuid)
      activeRecords.removeAll { $0.uuid == uuid }
      saveRecords()
    } catch {
      logger.warning("Expiry cleanup failed: \(error.localizedDescription)")
      if let idx = activeRecords.firstIndex(where: { $0.uuid == uuid }) {
        activeRecords[idx].pendingRemoval = true
        activeRecords[idx].retryCount += 1
        saveRecords()
        scheduleRetry(uuid: uuid)
      }
    }
  }

  private func scheduleRetry(uuid: String) {
    retryTasks[uuid] = Task { [weak self] in
      guard let self else { return }
      let retryCount = self.activeRecords.first { $0.uuid == uuid }?.retryCount ?? 0
      let backoff = self.backoffIntervals[min(retryCount, self.backoffIntervals.count - 1)]
      try? await Task.sleep(for: .seconds(backoff))
      await self.retryRemoval(uuid: uuid)
    }
  }

  private func retryRemoval(uuid: String) async {
    guard let record = activeRecords.first(where: { $0.uuid == uuid }),
      record.pendingRemoval
    else { return }

    do {
      try await wrapped.deleteDomain(domain: record.domain)
      retryTasks.removeValue(forKey: uuid)
      expiryTasks.removeValue(forKey: uuid)
      activeRecords.removeAll { $0.uuid == uuid }
      saveRecords()
    } catch PiholeError.unknown {
      retryTasks.removeValue(forKey: uuid)
      expiryTasks.removeValue(forKey: uuid)
      activeRecords.removeAll { $0.uuid == uuid }
      saveRecords()
    } catch {
      if let idx = activeRecords.firstIndex(where: { $0.uuid == uuid }) {
        activeRecords[idx].retryCount += 1
        saveRecords()
        scheduleRetry(uuid: uuid)
      }
    }
  }
}
