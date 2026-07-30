import Defaults
import Foundation
import OSLog
// swiftlint:disable file_length

@MainActor
public final class PiholeServerManager: ObservableObject {
  private static let maxServers = 2
  @Published public var servers: [ServerConfig] = []
  private let keychain: KeychainManaging
  private let serviceFactory: PiholeServiceFactory
  private let versionDetector: PiholeVersionDetector
  private let suite: UserDefaults
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "server-manager")
  private var services: [UUID: PiholeServiceProtocol] = [:]

  public init(
    keychain: KeychainManaging,
    serviceFactory: PiholeServiceFactory,
    versionDetector: PiholeVersionDetector,
    suite: UserDefaults = .standard
  ) {
    self.keychain = keychain
    self.serviceFactory = serviceFactory
    self.versionDetector = versionDetector
    self.suite = suite
    self.servers = []
    loadServers()
  }

  // MARK: - Server CRUD

  public func addServer(label: String?, icon: String? = nil, url: String, credential: String) async throws {
    guard servers.count < Self.maxServers else {
      throw PiholeError.unknown("Maximum of \(Self.maxServers) Pi-hole instances allowed")
    }

    guard let serverURL = URL(string: url) else {
      throw PiholeError.unknown("Invalid URL format")
    }

    guard !credential.isEmpty else {
      throw PiholeError.unknown("Credential is required")
    }

    let version = try await detectVersion(url: url)

    let config = ServerConfig(label: label, icon: icon, url: url, version: version)
    let session = makeSession(trusting: serverURL)
    let service = try serviceFactory.buildService(
      config: config,
      credential: credential,
      session: session,
      suite: suite
    )

    try await service.login()

    servers.append(config)
    services[config.id] = service
    saveServers()

    try keychain.saveCredential(credential, for: config.id)

    logger.info("Added server: \(config.label ?? config.url, privacy: .public)")
  }

  public func updateServer(
    id: UUID,
    label: String?,
    icon: String? = nil,
    url: String,
    credential: String?,
    version: ServerVersion? = nil
  ) {
    guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }

    if let existingService = services[id] {
      let urlChanged = url != existingService.url

      if let label { existingService.label = label }
      servers[idx].icon = icon
      existingService.url = url
      if let version { existingService.version = version }

      if urlChanged {
        reconnectExistingService(existingService, id: id, url: url, credential: credential)
      }
    } else {
      if let label { servers[idx].label = label }
      servers[idx].icon = icon
      servers[idx].url = url
      if let version { servers[idx].version = version }
    }

    if let credential, !credential.isEmpty {
      try? keychain.saveCredential(credential, for: id)
    }

    syncConfigs()
    saveServers()
    logger.info("Updated server: \(label ?? url, privacy: .public)")
  }

  public func deleteServer(id: UUID) {
    servers.removeAll { $0.id == id }
    saveServers()
    try? keychain.deleteCredential(for: id)
    if let service = services.removeValue(forKey: id) {
      Task { await service.logout() }
    }
    logger.info("Deleted server: \(id.uuidString, privacy: .public)")
  }

  // MARK: - Helpers

  private func reconnectExistingService(
    _ existingService: PiholeServiceProtocol,
    id: UUID,
    url: String,
    credential: String?
  ) {
    let currentCredential = credential ?? (try? keychain.readCredential(for: id)) ?? ""
    let config = ServerConfig(
      id: id,
      label: existingService.label,
      url: url,
      version: existingService.version
    )
    Task { await existingService.logout() }
    guard let serverURL = URL(string: url) else { return }
    let session = makeSession(trusting: serverURL)
    if let rebuilt = try? serviceFactory.buildService(
      config: config,
      credential: currentCredential,
      session: session,
      suite: suite
    ) {
      services[id] = rebuilt
    }
  }

  private func makeSession(trusting url: URL) -> URLSession {
    let hosts = Set(servers.compactMap { URL(string: $0.url)?.host } + [url.host].compactMap { $0 })
    let delegate = CertificateTrustDelegate(trustedHosts: hosts)
    return URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
  }

  private func detectVersion(url urlString: String) async throws -> ServerVersion {
    guard let url = URL(string: urlString) else {
      throw PiholeError.unknown("Invalid URL format")
    }

    let session = makeSession(trusting: url)
    defer { session.finishTasksAndInvalidate() }

    return try await versionDetector.detect(baseURL: url, session: session)
  }

  // MARK: - Status & Blocking

  /// Returns blocking status for all servers. Each entry is `nil` if that server was unreachable.
  public func getBlockingStatus() async -> [UUID: BlockingStatus?] {
    await withTaskGroup(of: (UUID, BlockingStatus?).self) { group in
      for config in servers {
        group.addTask {
          do {
            let status = try await self.getBlockingStatus(for: config.id)
            return (config.id, status)
          } catch {
            return (config.id, nil)
          }
        }
      }
      var results: [UUID: BlockingStatus?] = [:]
      for await (id, status) in group {
        results[id] = status
      }
      return results
    }
  }

  /// Per-server blocking check. Prefer the umbrella `getBlockingStatus()`.
  private func getBlockingStatus(for id: UUID) async throws -> BlockingStatus {
    guard let service = services[id] else {
      throw PiholeError.unknown("Server not found")
    }
    return try await service.checkStatus()
  }

  /// Toggle blocking on all servers. Returns per-server success/failure.
  public func setBlocking(enabled: Bool, duration: TimeInterval?) async -> [UUID: Bool] {
    await withTaskGroup(of: (UUID, Bool).self) { group in
      for config in servers {
        group.addTask {
          do {
            try await self.setBlocking(for: config.id, enabled: enabled, duration: duration)
            return (config.id, true)
          } catch {
            return (config.id, false)
          }
        }
      }
      var results: [UUID: Bool] = [:]
      for await (id, success) in group {
        results[id] = success
      }
      return results
    }
  }

  /// Per-server blocking toggle. Prefer the umbrella `setBlocking(enabled:duration:)`.
  private func setBlocking(for id: UUID, enabled: Bool, duration: TimeInterval?) async throws {
    guard let service = services[id] else {
      throw PiholeError.unknown("Server not found")
    }
    try await withRetry(.destructive) {
      try await service.setBlocking(enabled: enabled, duration: duration)
    }
  }

  public func updateServerVersion(id: UUID, version: ServerVersion) {
    services[id]?.version = version
    syncConfigs()
    saveServers()
  }

  // MARK: - Session Management

  public func logoutAll() async {
    await withTaskGroup(of: Void.self) { group in
      for (_, service) in services {
        group.addTask {
          await service.logout()
        }
      }
    }
    services.removeAll()
    syncConfigs()
  }

  public func reloadServers() {
    loadServers()
  }

  // MARK: - Typed Operations

  /// Unblock a domain on all servers. Returns per-server result (success or error).
  public func unblockDomain(_ domain: String, duration: TimeInterval?) async -> [UUID: Result<Void, any Error>] {
    let stripped = domain.hasPrefix("www.") ? String(domain.dropFirst(4)) : domain
    return await withTaskGroup(of: (UUID, Result<Void, any Error>).self) { group in
      for config in servers {
        group.addTask {
          do {
            try await self.unblockDomain(stripped, duration: duration, for: config.id)
            return (config.id, .success(()))
          } catch {
            return (config.id, .failure(error))
          }
        }
      }
      var results: [UUID: Result<Void, any Error>] = [:]
      for await (id, result) in group {
        results[id] = result
      }
      return results
    }
  }

  /// Per-server unblock. Prefer the umbrella `unblockDomain(_:duration:)`.
  private func unblockDomain(_ domain: String, duration: TimeInterval?, for serverID: UUID) async throws {
    guard let service = services[serverID] else { throw PiholeError.unknown("Server not found") }
    try await withRetry(.destructive) {
      try await service.unblockDomain(domain, duration: duration)
    }
  }

  public func deleteDomain(_ domain: String) async {
    let serverList = servers
    await withTaskGroup(of: Void.self) { group in
      for config in serverList {
        guard let service = services[config.id] else { continue }
        group.addTask {
          do {
            try await withRetry(.destructive) {
              try await service.deleteDomain(domain: domain)
            }
          } catch {
            self.logger.warning(
              "deleteDomain failed on \(config.label ?? config.url): \(error.localizedDescription, privacy: .public)"
            )
          }
        }
      }
    }
  }

  public func getDomains() async throws -> [UUID: [DomainEntry]] {
    let serverList = servers
    let collected: [(UUID, [DomainEntry])] = await withTaskGroup(
      of: (UUID, [DomainEntry])?.self
    ) { group in
      for config in serverList {
        guard let service = services[config.id] else { continue }
        group.addTask {
          do {
            let domains = try await service.getDomains()
            return (config.id, domains)
          } catch {
            self.logger.warning(
              "getDomains failed on \(config.label ?? config.url): \(error.localizedDescription, privacy: .public)"
            )
            return nil
          }
        }
      }

      var collected: [(UUID, [DomainEntry])] = []
      for await result in group {
        if let pair = result {
          collected.append(pair)
        }
      }
      return collected
    }
    return Dictionary(uniqueKeysWithValues: collected)
  }

  public func getRecentBlocked(forClientIp: String?, interval: DateInterval) async throws -> [BlockedDomain] {
    let serverList = servers
    let allBlocked: [BlockedDomain] = await withTaskGroup(
      of: [BlockedDomain].self
    ) { group in
      for config in serverList {
        guard let service = services[config.id] else { continue }
        group.addTask {
          do {
            return try await service.getRecentBlocked(forClientIp: forClientIp, interval: interval)
          } catch {
            let label = config.label ?? config.url
            self.logger.warning(
              "getRecentBlocked failed on \(label): \(error.localizedDescription, privacy: .public)")
            return []
          }
        }
      }

      var allBlocked: [BlockedDomain] = []
      for await result in group {
        allBlocked.append(contentsOf: result)
      }
      return allBlocked
    }
    // Deduplicate by domain keeping the most recent timestamp, count occurrences
    let deduped: [BlockedDomain] = Dictionary(grouping: allBlocked, by: \.domain)
      .mapValues { entries in
        let mostRecent = entries.max { $0.timestamp < $1.timestamp } ?? entries[0]
        return BlockedDomain(
          domain: mostRecent.domain,
          timestamp: mostRecent.timestamp,
          count: entries.count,
          fromClientIp: mostRecent.fromClientIp)
      }
      .values
      .sorted { $0.timestamp > $1.timestamp }
    return deduped
  }

  /// Returns query summaries for all servers. Each entry is `nil` if that server was unreachable.
  public func getQuerySummary() async -> [UUID: QuerySummary?] {
    await withTaskGroup(of: (UUID, QuerySummary?).self) { group in
      for config in servers {
        group.addTask {
          do {
            let summary = try await self.getQuerySummary(for: config.id)
            return (config.id, summary)
          } catch {
            return (config.id, nil)
          }
        }
      }
      var results: [UUID: QuerySummary?] = [:]
      for await (id, summary) in group {
        results[id] = summary
      }
      return results
    }
  }

  /// Per-server query summary. Prefer the umbrella `getQuerySummary()`.
  private func getQuerySummary(for serverID: UUID) async throws -> QuerySummary {
    guard let service = services[serverID] else { throw PiholeError.unknown("Server not found") }
    return try await service.getQuerySummary()
  }

  // MARK: - Multi-server workflows

  public func unblock(domain: String, duration: TimeInterval) async throws {
    guard !servers.isEmpty else { throw PiholeError.unknown("No configured Pi-hole instance") }

    let results = await unblockDomain(domain, duration: duration)
    let anySuccess = results.values.contains {
      if case .success = $0 { return true }
      return false
    }
    guard anySuccess else {
      let lastError = results.values.compactMap {
        if case .failure(let error) = $0 { return error }
        return nil
      }.last
      throw lastError ?? PiholeError.unknown("Failed to unblock on all servers")
    }
  }

  public func addToAllowlist(domain: String) async {
    let results = await unblockDomain(domain, duration: nil)
    for (configId, result) in results {
      if case .failure(let error) = result {
        let label = servers.first { $0.id == configId }?.label ?? configId.uuidString
        self.logger.warning(
          "Allowlist failed on \(label): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  // MARK: - Persistence

  private func loadServers() {
    let configs: [ServerConfig] = Defaults[.servers(suite: suite)]
    logger.debug("loadServers: found \(configs.count) configs")

    if configs.isEmpty {
      logger.debug("loadServers: Defaults returned empty — no persisted servers")
    }

    servers = configs

    for config in servers {
      guard let credential = try? keychain.readCredential(for: config.id) else {
        logger.warning("No credential found for server \(config.id), skipping")
        continue
      }
      guard let serverURL = URL(string: config.url) else { continue }
      let session = makeSession(trusting: serverURL)
      if let rebuilt = try? serviceFactory.buildService(
        config: config,
        credential: credential,
        session: session,
        suite: suite
      ) {
        services[config.id] = rebuilt
      }
    }

    syncConfigs()

    // Warm up sessions so first concurrent requests don't trigger
    // the actor-reentrancy race in acquireSession().
    for (_, service) in services {
      Task { try? await service.login() }
    }
  }

  private func saveServers() {
    Defaults[.servers(suite: suite)] = servers
  }

  private func syncConfigs() {
    servers = servers.map { config in
      if let svc = services[config.id] {
        return ServerConfig(id: svc.id, label: svc.label, icon: config.icon, url: svc.url, version: svc.version)
      }
      return config
    }
  }
}
