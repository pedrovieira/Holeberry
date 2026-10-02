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
  public var isPasswordless: Bool {
    get async { await wrapped.isPasswordless }
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
    sleep: @escaping (TimeInterval) async throws -> Void = { try await sleepForSeconds($0) }
  ) {
    self.wrapped = service
    self.backoffIntervals = backoffIntervals
    self.defaultsSuite = defaultsSuite
    self.notificationCenter = notificationCenter
    self.sleep = sleep
    self.activeRecords = restoreFromDefaults()
    saveRecords()
    if !activeRecords.isEmpty {
      Task { await reconcileWithServer() }
    }
  }

  // MARK: - Passthrough methods

  public func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainAddOutcome {
    try await wrapped.addDomain(domain, to: list, comment: comment)
  }

  public func deleteDomain(_ domain: String, from list: DomainListType) async throws {
    try await wrapped.deleteDomain(domain, from: list)
    // Only allow entries have a matching temp-unblock record to drop.
    if list == .allow {
      let identity = PiholeDomain.identity(domain)
      for record in activeRecords where record.domain == identity {
        expiryTasks.removeValue(forKey: record.uuid)?.cancel()
        retryTasks.removeValue(forKey: record.uuid)?.cancel()
      }
      activeRecords.removeAll { $0.domain == identity }
      saveRecords()
    }
  }

  public func checkStatus() async throws -> BlockingStatus {
    try await wrapped.checkStatus()
  }

  public func getQuerySummary() async throws -> QuerySummary {
    try await wrapped.getQuerySummary()
  }

  public func updateGravity() async throws {
    try await wrapped.updateGravity()
  }

  public func setBlocking(enabled: Bool, duration: TimeInterval?) async throws {
    try await wrapped.setBlocking(enabled: enabled, duration: duration)
  }

  public func getRecentBlocked(forClientIp: String?, interval: DateInterval) async throws -> [BlockedDomain] {
    try await wrapped.getRecentBlocked(forClientIp: forClientIp, interval: interval)
  }

  public func getDomains(from list: DomainListType) async throws -> [DomainEntry] {
    try await wrapped.getDomains(from: list)
  }

  public func getDomain(_ domain: String, from list: DomainListType) async throws -> DomainEntry? {
    try await wrapped.getDomain(domain, from: list)
  }

  public func logout() async {
    await wrapped.logout()
  }

  public func login() async throws {
    try await wrapped.login()
  }

  // MARK: - Unblock

  @discardableResult
  public func unblockDomain(_ domain: String, duration: TimeInterval?) async throws -> DomainUnblockOutcome {
    let identity = try PiholeDomain.validatedIdentity(domain)
    try Task.checkCancellation()
    guard let duration else {
      let outcome = try await wrapped.addDomain(identity, to: .allow, comment: "via holeberryapp.com")
      return await DomainUnblockOutcome.resolve(for: identity, addOutcome: outcome, service: wrapped)
    }
    let uuid = "via holeberryapp.com / \(UUID().uuidString)"
    let startDate = Date()
    let outcome = try await addTemporaryDomain(identity, comment: uuid)
    guard outcome == .added else {
      return await DomainUnblockOutcome.resolve(for: identity, addOutcome: outcome, service: wrapped)
    }
    let record = TempUnblockRecord(
      domain: identity, uuid: uuid, startDateUTC: startDate, durationSeconds: duration
    )
    activeRecords.append(record)
    saveRecords()
    startExpiryTask(for: record)
    return .added
  }

  private func addTemporaryDomain(_ domain: String, comment: String) async throws -> DomainAddOutcome {
    do {
      return try await wrapped.addDomain(domain, to: .allow, comment: comment)
    } catch {
      // An add can commit before its response is lost. Make one lookup to
      // recover this attempt; otherwise preserve the original error.
      let existing = try? await wrapped.getDomain(domain, from: .allow)
      guard existing?.comment == comment else { throw error }
      return .added
    }
  }

  // MARK: - Persistence

  private func restoreFromDefaults() -> [TempUnblockRecord] {
    Defaults[.tempUnblocks(for: wrapped.id, suite: defaultsSuite)].map { record in
      TempUnblockRecord(
        domain: PiholeDomain.identity(record.domain),
        uuid: record.uuid,
        startDateUTC: record.startDateUTC,
        durationSeconds: record.durationSeconds,
        pendingRemoval: record.pendingRemoval,
        retryCount: record.retryCount
      )
    }
  }

  private func saveRecords() {
    Defaults[.tempUnblocks(for: wrapped.id, suite: defaultsSuite)] = activeRecords
  }

  // MARK: - Init-time reconciliation

  /// Reconciliation task captures the records at init time and only processes those.
  private func reconcileWithServer() async {
    let initialRecords = activeRecords
    guard !initialRecords.isEmpty else { return }

    guard let domains = try? await wrapped.getDomains(from: .allow) else {
      resumeCleanup(for: initialRecords)
      return
    }
    let serverDomains = Set(domains.map { PiholeDomain.identity($0.domain) })
    activeRecords = activeRecords.filter { record in
      // Preserve records created while the reconciliation request was in flight.
      guard initialRecords.contains(where: { $0.uuid == record.uuid }) else { return true }
      return serverDomains.contains(record.domain)
    }
    saveRecords()
    resumeCleanup(for: activeRecords)
  }

  private func resumeCleanup(for records: [TempUnblockRecord]) {
    for record in records {
      if record.pendingRemoval {
        scheduleRetry(uuid: record.uuid)
      } else {
        startExpiryTask(for: record)
      }
    }
  }

  // MARK: - Expiry

  private func startExpiryTask(for record: TempUnblockRecord) {
    expiryTasks.removeValue(forKey: record.uuid)?.cancel()
    let remaining = max(0, record.startDateUTC.addingTimeInterval(record.durationSeconds).timeIntervalSinceNow)
    expiryTasks[record.uuid] = Task { [weak self] in
      do {
        try await self?.sleep(remaining)
      } catch {
        return
      }
      await self?.removeExpired(uuid: record.uuid)
    }
  }

  private func removeExpired(uuid: String) async {
    guard let record = activeRecords.first(where: { $0.uuid == uuid }) else { return }

    do {
      try await wrapped.deleteDomain(record.domain, from: .allow)
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
    retryTasks.removeValue(forKey: uuid)?.cancel()
    retryTasks[uuid] = Task { [weak self] in
      guard let self else { return }
      let retryCount = self.activeRecords.first { $0.uuid == uuid }?.retryCount ?? 0
      let backoff = self.backoffIntervals[min(retryCount, self.backoffIntervals.count - 1)]
      do {
        try await self.sleep(backoff)
      } catch {
        return
      }
      await self.retryRemoval(uuid: uuid)
    }
  }

  private func retryRemoval(uuid: String) async {
    guard let record = activeRecords.first(where: { $0.uuid == uuid }),
      record.pendingRemoval
    else { return }

    do {
      try await wrapped.deleteDomain(record.domain, from: .allow)
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
    expiryTasks.removeValue(forKey: uuid)?.cancel()
    retryTasks.removeValue(forKey: uuid)?.cancel()
    activeRecords.removeAll { $0.uuid == uuid }
    saveRecords()
    notificationCenter.post(
      name: .domainUnblockExpired,
      object: nil,
      userInfo: [AppNotificationUserInfoKey.domain: domain]
    )
  }
}
