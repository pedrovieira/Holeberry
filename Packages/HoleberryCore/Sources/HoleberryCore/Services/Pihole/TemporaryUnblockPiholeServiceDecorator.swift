import Defaults
import Foundation
import OSLog

@MainActor
public final class TemporaryUnblockPiholeServiceDecorator: PiholeServiceProviding {
  private let wrapped: any PiholeAPIProviding

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
  // A present key holds the domain across network awaits, with FIFO waiters.
  private var domainWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  private let backoffIntervals: [TimeInterval]
  private let defaultsSuite: UserDefaults
  private let notificationCenter: NotificationCenter
  private let retrySleep: @Sendable (Duration) async throws -> Void
  private let sleep: (TimeInterval) async throws -> Void
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "temp-unblock")

  public init(
    service: any PiholeAPIProviding,
    backoffIntervals: [TimeInterval] = [10, 30, 120, 600],
    defaultsSuite: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default,
    retrySleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await ContinuousClock().sleep(for: $0)
    },
    sleep: @escaping (TimeInterval) async throws -> Void = { try await sleepForSeconds($0) }
  ) {
    self.wrapped = service
    self.backoffIntervals = backoffIntervals
    self.defaultsSuite = defaultsSuite
    self.notificationCenter = notificationCenter
    self.retrySleep = retrySleep
    self.sleep = sleep
    self.activeRecords = restoreFromDefaults()
    saveRecords()
    if !activeRecords.isEmpty {
      let records = activeRecords
      Task { await reconcileWithServer(records) }
    }
  }

  // MARK: - Passthrough methods

  public func addDomain(_ domain: String, to list: DomainListType, comment: String?) async throws -> DomainAddOutcome {
    try await wrapped.addDomain(domain, to: list, comment: comment)
  }

  public func deleteDomain(_ domain: String, from list: DomainListType) async throws {
    guard list == .allow else {
      try await wrapped.deleteDomain(domain, from: list)
      return
    }
    let identity = PiholeDomain.identity(domain)
    await acquireDomain(identity)
    defer { releaseDomain(identity) }
    try Task.checkCancellation()
    try await wrapped.deleteDomain(domain, from: list)
    cancelRecords(for: identity)
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
    _ domain: String, duration: TimeInterval?
  ) async throws -> DomainUnblockOutcome {
    let identity = try PiholeDomain.validatedIdentity(domain)
    try Task.checkCancellation()
    let token = "via holeberryapp.com / \(UUID().uuidString)"
    return try await withRetry(.destructive, sleep: retrySleep) {
      try await self.attemptUnblock(identity, duration: duration, token: token)
    }
  }

  private func attemptUnblock(
    _ identity: String, duration: TimeInterval?, token: String
  ) async throws -> DomainUnblockOutcome {
    await acquireDomain(identity)
    defer { releaseDomain(identity) }
    try Task.checkCancellation()
    let comment = duration == nil ? "via holeberryapp.com" : token
    let outcome: DomainAddOutcome
    do {
      outcome = try await wrapped.addDomain(identity, to: .allow, comment: comment)
    } catch {
      // An insert may commit before its response is lost. This call's token
      // stays stable across mutation retries, so that attempt can be adopted.
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

  /// Classifies an existing allow entry as request recovery, renewal, promotion, or an unrelated entry.
  ///
  /// A comment matching this request's token recovers its earlier insert and returns `.added`,
  /// starting or resetting the temporary timer even if no local record was saved yet.
  /// A later unblock has a new token: ownership is checked against the saved record's token instead.
  /// On v6, the entry's comment must match that saved token; v5 relies on the local record alone.
  /// A finite duration renews the saved record from now with the selected duration, retaining its token.
  /// A nil duration promotes it by cancelling local cleanup. Neither operation changes the server comment.
  /// Disabled entries always report `.alreadyPresent(enabled: false)` without changing local timers.
  /// Missing entries, missing ownership records, or changed v6 comments report `.alreadyPresent`,
  /// unless the current request's token matched and allowed recovery above.
  private func classifyExisting(
    _ entry: DomainEntry?, key: String, duration: TimeInterval?, token: String
  ) -> DomainUnblockOutcome {
    guard let entry else { return .alreadyPresent(enabled: nil) }
    if entry.enabled == false { return .alreadyPresent(enabled: false) }
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
    cancelRecords(for: domain)
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

  /// Only resume unchanged records captured at init, never a later renewal.
  private func reconcileWithServer(_ records: [TempUnblockRecord]) async {
    let domains = try? await wrapped.getDomains(from: .allow)
    let serverDomains = domains.map { Set($0.map { PiholeDomain.identity($0.domain) }) }
    await withTaskGroup(of: Void.self) { group in
      for record in records {
        group.addTask {
          await self.reconcileRecord(record, serverDomains: serverDomains)
        }
      }
    }
  }

  private func reconcileRecord(_ record: TempUnblockRecord, serverDomains: Set<String>?) async {
    await acquireDomain(record.domain)
    defer { releaseDomain(record.domain) }
    guard activeRecords.contains(record) else { return }
    if let serverDomains, !serverDomains.contains(record.domain) {
      cancelRecords(for: record.domain)
    } else if record.pendingRemoval {
      scheduleRetry(for: record)
    } else {
      startExpiryTask(for: record)
    }
  }

  // MARK: - Per-domain operations

  private func acquireDomain(_ domain: String) async {
    guard domainWaiters[domain] != nil else {
      domainWaiters[domain] = []
      return
    }
    await withCheckedContinuation { domainWaiters[domain, default: []].append($0) }
  }

  private func releaseDomain(_ domain: String) {
    guard var waiters = domainWaiters[domain], !waiters.isEmpty else {
      domainWaiters.removeValue(forKey: domain)
      return
    }
    let next = waiters.removeFirst()
    domainWaiters[domain] = waiters
    next.resume()
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
      await self?.removeExpired(record)
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

  private func removeExpired(_ record: TempUnblockRecord) async {
    await acquireDomain(record.domain)
    defer { releaseDomain(record.domain) }
    guard !Task.isCancelled else { return }
    // Keep the gate through both network awaits and local updates. A renewal
    // must wait for any DELETE already sent, then inspect the resulting entry.
    switch await attemptRemoval(record) {
    case .removed, .alreadyGone:
      finalizeExpiry(uuid: record.uuid, domain: record.domain)
    case .notOurs:
      finalizeExpiry(uuid: record.uuid, domain: record.domain, notify: false)
    case .retry:
      logger.warning("Expiry cleanup failed, will retry: \(record.domain)")
      if let index = activeRecords.firstIndex(where: { $0.uuid == record.uuid }) {
        activeRecords[index].pendingRemoval = true
        activeRecords[index].retryCount += 1
        saveRecords()
        scheduleRetry(for: activeRecords[index])
      }
    }
  }

  private func scheduleRetry(for record: TempUnblockRecord) {
    retryTasks.removeValue(forKey: record.uuid)?.cancel()
    retryTasks[record.uuid] = Task { [weak self] in
      guard let self else { return }
      let backoff = self.backoffIntervals[min(record.retryCount, self.backoffIntervals.count - 1)]
      do {
        try await self.sleep(backoff)
      } catch {
        return
      }
      await self.removeExpired(record)
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
