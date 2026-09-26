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
    if !activeRecords.isEmpty {
      Task { await reconcileWithServer() }
    }
  }

  // MARK: - Passthrough methods

  public func addDomain(_ domain: String, to list: DomainListType) async throws -> DomainListAddResult {
    try await wrapped.addDomain(domain, to: list, comment: nil)
  }

  public func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainListAddResult
  {
    try await wrapped.addDomain(domain, to: list, comment: comment)
  }

  public func allowEntry(_ domain: String) async throws -> DomainEntry? {
    try await wrapped.allowEntry(domain)
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

  public func updateGravity() async throws {
    try await wrapped.updateGravity()
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

  private static let indefiniteComment = "via holeberryapp.com"
  private static let ownershipCommentPrefix = "via holeberryapp.com / "

  public func unblockDomain(
    _ domain: String, duration: TimeInterval?, ownershipID: UUID
  ) async throws -> UnblockOutcome {
    let key = domain.lowercased()  // FTL stores lowercase; the v6 read-back is case-sensitive
    let token = "\(Self.ownershipCommentPrefix)\(ownershipID.uuidString)"
    switch wrapped.version {
    case .v5:
      return try await unblockV5(key: key, duration: duration, token: token)
    case .v6:
      return try await unblockV6(key: key, duration: duration, token: token)
    }
  }

  private func unblockV5(key: String, duration: TimeInterval?, token: String) async throws -> UnblockOutcome {
    if let entry = try await wrapped.allowEntry(key) {
      return classifyExisting(entry, key: key, duration: duration, token: token, verifiesOwnership: false)
    }
    _ = try await wrapped.addDomain(key, to: .allow, comment: nil)
    if let duration {
      startRecord(domain: key, duration: duration, uuid: token)
    }
    return .added
  }

  private func unblockV6(key: String, duration: TimeInterval?, token: String) async throws -> UnblockOutcome {
    let comment = duration == nil ? Self.indefiniteComment : token
    do {
      switch try await wrapped.addDomain(key, to: .allow, comment: comment) {
      case .inserted:
        if let duration {
          startRecord(domain: key, duration: duration, uuid: token)
        }
        return .added
      case .notInserted(let entry):
        return classifyExisting(entry, key: key, duration: duration, token: token, verifiesOwnership: true)
      }
    } catch {
      // 400 stub (FTL >= 6.6.1) or unparseable reply: disambiguate with ONE read-back.
      guard let entry = try? await wrapped.allowEntry(key) else {
        throw error
      }
      return classifyExisting(entry, key: key, duration: duration, token: token, verifiesOwnership: true)
    }
  }

  private func classifyExisting(
    _ entry: DomainEntry, key: String, duration: TimeInterval?, token: String, verifiesOwnership: Bool
  ) -> UnblockOutcome {
    if verifiesOwnership, entry.comment == token {
      if let duration {
        startRecord(domain: key, duration: duration, uuid: token)
      }
      return .added
    }
    if let record = activeRecords.first(where: { $0.domain == key }),
      !verifiesOwnership || entry.comment == record.uuid
    {
      if let duration {
        renewRecord(record, duration: duration)
        return .renewed
      }
      cancelRecords(for: key)
      return .promoted
    }
    return entry.enabled == false ? .ineffective : .alreadyAllowed
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
    guard let idx = activeRecords.firstIndex(where: { $0.uuid == record.uuid }) else { return }
    let renewed = TempUnblockRecord(
      domain: record.domain, uuid: record.uuid, startDateUTC: Date(), durationSeconds: duration)
    activeRecords[idx] = renewed
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

  private enum RemovalOutcome {
    case removed  // server confirmed the deletion
    case alreadyGone  // nothing to delete (absent entry, v6 404, or .unknown)
    case notOurs  // entry exists but the comment is not this record's — leave it
    case retry  // transient failure — keep trying with backoff
  }

  private func startExpiryTask(for record: TempUnblockRecord) {
    expiryTasks[record.uuid] = Task { [weak self] in
      try? await self?.sleep(record.durationSeconds)
      await self?.removeExpired(uuid: record.uuid)
    }
  }

  /// Probes for ownership before deleting: a pre-existing entry that is not
  /// ours is never touched, and a missing entry (or a v6 404 on delete) ends
  /// the record instead of retrying forever.
  private func attemptRemoval(_ record: TempUnblockRecord) async -> RemovalOutcome {
    do {
      let entry = try await wrapped.allowEntry(record.domain)
      if wrapped.version == .v6, let entry, entry.comment != record.uuid {
        return .notOurs
      }
      guard entry != nil else { return .alreadyGone }
      try await wrapped.deleteDomain(domain: record.domain)
      return .removed
    } catch PiholeError.unknown {
      return .alreadyGone
    } catch let PiholeError.server(code, _) where code == 404 {
      return .alreadyGone
    } catch {
      return .retry
    }
  }

  private func removeExpired(uuid: String) async {
    guard let record = activeRecords.first(where: { $0.uuid == uuid }) else { return }

    switch await attemptRemoval(record) {
    case .removed, .alreadyGone:
      finishRemoval(uuid: uuid, domain: record.domain, notify: true)
    case .notOurs:
      // The entry is not ours anymore; drop the record silently (no "blocked
      // again" claim — the domain is still allowed).
      finishRemoval(uuid: uuid, domain: record.domain, notify: false)
    case .retry:
      logger.warning("Expiry cleanup failed, will retry: \(record.domain)")
      markForRetry(uuid: uuid)
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

    switch await attemptRemoval(record) {
    case .removed, .alreadyGone:
      finishRemoval(uuid: uuid, domain: record.domain, notify: true)
    case .notOurs:
      finishRemoval(uuid: uuid, domain: record.domain, notify: false)
    case .retry:
      if let idx = activeRecords.firstIndex(where: { $0.uuid == uuid }) {
        activeRecords[idx].retryCount += 1
        saveRecords()
        scheduleRetry(uuid: uuid)
      }
    }
  }

  private func markForRetry(uuid: String) {
    if let idx = activeRecords.firstIndex(where: { $0.uuid == uuid }) {
      activeRecords[idx].pendingRemoval = true
      activeRecords[idx].retryCount += 1
      saveRecords()
      scheduleRetry(uuid: uuid)
    }
  }

  /// Drops the record after a successful (or server-confirmed) expiry cleanup.
  /// Posts `.domainUnblockExpired` only when `notify` — a not-ours entry stays
  /// allowed, so "blocked again" would be wrong.
  private func finishRemoval(uuid: String, domain: String, notify: Bool) {
    expiryTasks.removeValue(forKey: uuid)
    retryTasks.removeValue(forKey: uuid)
    activeRecords.removeAll { $0.uuid == uuid }
    saveRecords()
    if notify {
      notificationCenter.post(
        name: .domainUnblockExpired,
        object: nil,
        userInfo: [AppNotificationUserInfoKey.domain: domain]
      )
    }
  }
}
