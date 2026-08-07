import Defaults
import Foundation
import OSLog

@MainActor
public final class TemporaryUnblockPiholeServiceDecorator: PiholeServiceCommentAdding {
  private let wrapped: any PiholeServiceCommentAdding

  // Identity — delegates to wrapped
  public var id: UUID { wrapped.id }
  public var label: String? {
    get { wrapped.label }
    set { wrapped.label = newValue }
  }
  public var url: String {
    get { wrapped.url }
    set { wrapped.url = newValue }
  }
  public var version: ServerVersion {
    get { wrapped.version }
    set { wrapped.version = newValue }
  }

  // Unblock state — per-server
  private var activeRecords: [TempUnblockRecord] = []
  private var expiryTasks: [String: Task<Void, Never>] = [:]
  private var retryTasks: [String: Task<Void, Never>] = [:]
  private let backoffIntervals: [TimeInterval]
  private let defaultsSuite: UserDefaults
  private let notificationCenter: NotificationCenter
  private let sleep: (TimeInterval) async throws -> Void
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "temp-unblock")

  public init(
    service: any PiholeServiceCommentAdding,
    backoffIntervals: [TimeInterval] = [10, 30, 120, 600],
    defaultsSuite: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default,
    sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
  ) {
    self.wrapped = service
    self.backoffIntervals = backoffIntervals
    self.defaultsSuite = defaultsSuite
    self.notificationCenter = notificationCenter
    self.sleep = sleep
    self.activeRecords = restoreFromDefaults()
    if !activeRecords.isEmpty {
      Task { await reconcileWithServer() }
    }
  }

  // MARK: - Passthrough methods

  public func addDomain(_ domain: String, to list: DomainListType) async throws -> DomainEntry {
    try await wrapped.addDomain(domain, to: list, comment: nil)
  }

  public func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainEntry {
    try await wrapped.addDomain(domain, to: list, comment: comment)
  }

  public func deleteDomain(domain: String) async throws {
    try await wrapped.deleteDomain(domain: domain)
    activeRecords.removeAll { $0.domain == domain }
    saveRecords()
  }

  public func checkStatus() async throws -> BlockingStatus {
    try await wrapped.checkStatus()
  }

  public func getQuerySummary() async throws -> QuerySummary {
    try await wrapped.getQuerySummary()
  }

  public func setBlocking(enabled: Bool, duration: TimeInterval?) async throws {
    try await wrapped.setBlocking(enabled: enabled, duration: duration)
  }

  public func getRecentBlocked(forClientIp: String?, interval: DateInterval) async throws -> [BlockedDomain] {
    try await wrapped.getRecentBlocked(forClientIp: forClientIp, interval: interval)
  }

  public func getDomains() async throws -> [DomainEntry] {
    try await wrapped.getDomains()
  }

  public func logout() async {
    await wrapped.logout()
  }

  public func login() async throws {
    try await wrapped.login()
  }

  // MARK: - Unblock

  public func unblockDomain(_ domain: String, duration: TimeInterval?) async throws {
    if let duration {
      let uuid = "via holeberryapp.com / \(UUID().uuidString)"
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
      _ = try await wrapped.addDomain(domain, to: .allow, comment: "via holeberryapp.com")
    }
  }

  // MARK: - Persistence

  private func restoreFromDefaults() -> [TempUnblockRecord] {
    Defaults[.tempUnblocks(for: wrapped.id, suite: defaultsSuite)]
  }

  private func saveRecords() {
    Defaults[.tempUnblocks(for: wrapped.id, suite: defaultsSuite)] = activeRecords
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
      try? await self?.sleep(record.durationSeconds)
      await self?.removeExpired(uuid: record.uuid)
    }
  }

  private func removeExpired(uuid: String) async {
    guard let record = activeRecords.first(where: { $0.uuid == uuid }) else { return }

    do {
      try await wrapped.deleteDomain(domain: record.domain)
      finalizeExpiry(uuid: uuid, domain: record.domain)
    } catch PiholeError.unknown {
      finalizeExpiry(uuid: uuid, domain: record.domain)
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
      try? await self.sleep(backoff)
      await self.retryRemoval(uuid: uuid)
    }
  }

  private func retryRemoval(uuid: String) async {
    guard let record = activeRecords.first(where: { $0.uuid == uuid }),
      record.pendingRemoval
    else { return }

    do {
      try await wrapped.deleteDomain(domain: record.domain)
      finalizeExpiry(uuid: uuid, domain: record.domain)
    } catch PiholeError.unknown {
      finalizeExpiry(uuid: uuid, domain: record.domain)
    } catch {
      if let idx = activeRecords.firstIndex(where: { $0.uuid == uuid }) {
        activeRecords[idx].retryCount += 1
        saveRecords()
        scheduleRetry(uuid: uuid)
      }
    }
  }

  /// Drops the record after a successful (or server-confirmed) expiry cleanup
  /// and posts `.domainUnblockExpired` so the app can notify the user that the
  /// unblock ended on its own.
  private func finalizeExpiry(uuid: String, domain: String) {
    expiryTasks.removeValue(forKey: uuid)
    retryTasks.removeValue(forKey: uuid)
    activeRecords.removeAll { $0.uuid == uuid }
    saveRecords()
    notificationCenter.post(
      name: .domainUnblockExpired,
      object: nil,
      userInfo: [AppNotificationUserInfoKey.domain: domain]
    )
  }
}
