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
  public func unblockDomain(
    _ domain: String, duration: TimeInterval?, ownershipID: UUID
  ) async throws -> DomainUnblockOutcome {
    let identity = try PiholeDomain.validatedIdentity(domain)
    try Task.checkCancellation()
    let token = "via holeberryapp.com / \(ownershipID.uuidString)"
    let comment = duration == nil ? "via holeberryapp.com" : token
    let outcome: DomainAddOutcome
    do {
      outcome = try await wrapped.addDomain(identity, to: .allow, comment: comment)
    } catch {
      // An insert may commit before its response is lost. The ownership ID
      // stays stable across manager retries, so that attempt can be adopted.
      guard let existing = try? await wrapped.getDomain(identity, from: .allow) else { throw error }
      if existing.comment == token, duration != nil {
        return classifyExisting(existing, key: identity, duration: duration, token: token)
      }
      // Failed v6 inserts can use 400, a 201 with processed errors, or an
      // unparseable reply. Resolve them from the row rather than hint text.
      if wrapped.version == .v6 {
        switch error {
        case PiholeError.server(400, _), PiholeError.server(201, _), PiholeError.decoding:
          return classifyExisting(existing, key: identity, duration: duration, token: token)
        default:
          break
        }
      }
      throw error
    }
    guard outcome == .added else {
      let existing = try? await wrapped.getDomain(identity, from: .allow)
      return classifyExisting(existing, key: identity, duration: duration, token: token)
    }
    if let duration {
      startRecord(domain: identity, duration: duration, uuid: token)
    }
    return .added
  }

  private func classifyExisting(
    _ entry: DomainEntry?, key: String, duration: TimeInterval?, token: String
  ) -> DomainUnblockOutcome {
    guard let entry else { return .alreadyPresent(enabled: nil) }
    if entry.comment == token, let duration {
      if let record = activeRecords.first(where: { $0.domain == key && $0.uuid == token }) {
        renewRecord(record, duration: duration)
      } else {
        startRecord(domain: key, duration: duration, uuid: token)
      }
      return .added
    }
    if let record = activeRecords.first(where: { $0.domain == key }),
      wrapped.version == .v5 || entry.comment == record.uuid
    {
      if let duration {
        renewRecord(record, duration: duration)
        return .renewed
      }
      cancelRecords(for: key)
      return .promoted
    }
    return .alreadyPresent(enabled: entry.enabled)
  }

  private func startRecord(domain: String, duration: TimeInterval, uuid: String) {
    let record = TempUnblockRecord(domain: domain, uuid: uuid, startDateUTC: Date(), durationSeconds: duration)
    activeRecords.append(record)
    saveRecords()
    startExpiryTask(for: record)
  }

  private func renewRecord(_ record: TempUnblockRecord, duration: TimeInterval) {
    expiryTasks.removeValue(forKey: record.uuid)?.cancel()
    retryTasks.removeValue(forKey: record.uuid)?.cancel()
    guard let index = activeRecords.firstIndex(where: { $0.uuid == record.uuid }) else { return }
    let renewed = TempUnblockRecord(
      domain: record.domain, uuid: record.uuid, startDateUTC: Date(), durationSeconds: duration)
    activeRecords[index] = renewed
    saveRecords()
    startExpiryTask(for: renewed)
  }

  private func cancelRecords(for domain: String) {
    for record in activeRecords where record.domain == domain {
      expiryTasks.removeValue(forKey: record.uuid)?.cancel()
      retryTasks.removeValue(forKey: record.uuid)?.cancel()
    }
    activeRecords.removeAll { $0.domain == domain }
    saveRecords()
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

  private enum RemovalOutcome {
    case removed
    case alreadyGone
    case notOurs
    case retry
  }

  private func attemptRemoval(_ record: TempUnblockRecord) async -> RemovalOutcome {
    do {
      guard let entry = try await wrapped.getDomain(record.domain, from: .allow) else { return .alreadyGone }
      if wrapped.version == .v6, entry.comment != record.uuid { return .notOurs }
      try await wrapped.deleteDomain(record.domain, from: .allow)
      return .removed
    } catch PiholeError.unknown, PiholeError.invalidDomain {
      return .alreadyGone
    } catch PiholeError.server(let code, _) where code == 404 {
      return .alreadyGone
    } catch {
      return .retry
    }
  }

  private func removeExpired(uuid: String) async {
    guard let record = activeRecords.first(where: { $0.uuid == uuid }) else { return }
    switch await attemptRemoval(record) {
    case .removed, .alreadyGone:
      finalizeExpiry(uuid: uuid, domain: record.domain)
    case .notOurs:
      finalizeExpiry(uuid: uuid, domain: record.domain, notify: false)
    case .retry:
      logger.warning("Expiry cleanup failed, will retry: \(record.domain)")
      if let index = activeRecords.firstIndex(where: { $0.uuid == uuid }) {
        activeRecords[index].pendingRemoval = true
        activeRecords[index].retryCount += 1
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

    switch await attemptRemoval(record) {
    case .removed, .alreadyGone:
      finalizeExpiry(uuid: uuid, domain: record.domain)
    case .notOurs:
      finalizeExpiry(uuid: uuid, domain: record.domain, notify: false)
    case .retry:
      if let index = activeRecords.firstIndex(where: { $0.uuid == uuid }) {
        activeRecords[index].retryCount += 1
        saveRecords()
        scheduleRetry(uuid: uuid)
      }
    }
  }

  /// Drops the record after expiry cleanup. Ownership changes finish silently:
  /// the entry remains allowed, so an unblock-ended notification would mislead.
  private func finalizeExpiry(uuid: String, domain: String, notify: Bool = true) {
    expiryTasks.removeValue(forKey: uuid)?.cancel()
    retryTasks.removeValue(forKey: uuid)?.cancel()
    activeRecords.removeAll { $0.uuid == uuid }
    saveRecords()
    guard notify else { return }
    notificationCenter.post(
      name: .domainUnblockExpired,
      object: nil,
      userInfo: [AppNotificationUserInfoKey.domain: domain]
    )
  }
}
