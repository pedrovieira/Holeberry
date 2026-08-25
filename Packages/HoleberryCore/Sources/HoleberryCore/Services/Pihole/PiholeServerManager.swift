import Combine
import Defaults
import Foundation
import OSLog
// swiftlint:disable file_length type_body_length

@MainActor
public final class PiholeServerManager: PiholeServerManaging, ObservableObject {
  private static let maxServers = 2
  @Published public var servers: [ServerConfig] = []
  public var serversPublisher: Published<[ServerConfig]>.Publisher { $servers }
  private let keychain: any KeychainManaging
  private let serviceFactory: any PiholeServiceFactory
  private let versionDetector: any PiholeVersionDetecting
  private let suite: UserDefaults
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "server-manager")
  private var services: [UUID: any PiholeServiceProviding] = [:]

  public init(
    keychain: any KeychainManaging,
    serviceFactory: any PiholeServiceFactory,
    versionDetector: any PiholeVersionDetecting,
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

    // Empty credential = password-less instance; login still validates.
    let version = try await detectVersion(url: url)

    let config = ServerConfig(
      label: label,
      icon: icon,
      url: url,
      version: version,
      isPasswordless: credential.isEmpty
    )
    let session = makeSession(trusting: serverURL)
    let service = try serviceFactory.buildService(
      config: config,
      credential: credential,
      session: session,
      suite: suite
    )

    try await service.login()

    // Keychain holds only real secrets; password-less is tracked in the config.
    if credential.isEmpty {
      try? keychain.deleteCredential(for: config.id)
    } else {
      try keychain.saveCredential(credential, for: config.id)
    }

    servers.append(config)
    services[config.id] = service
    saveServers()

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
      let credentialChanged: Bool
      if let credential {
        // nil = no change; "" = clear (password-less).
        credentialChanged = (try? keychain.readCredential(for: id)) != credential
      } else {
        credentialChanged = false
      }

      if let label { existingService.label = label }
      servers[idx].icon = icon
      existingService.url = url
      if let version { existingService.version = version }

      if urlChanged || credentialChanged {
        reconnectExistingService(existingService, id: id, url: url, credential: credential)
      }
    } else {
      if let label { servers[idx].label = label }
      servers[idx].icon = icon
      servers[idx].url = url
      if let version { servers[idx].version = version }
    }

    if let credential {
      servers[idx].isPasswordless = credential.isEmpty
      // Clear the keychain item when switching to password-less.
      if credential.isEmpty {
        try? keychain.deleteCredential(for: id)
      } else {
        try? keychain.saveCredential(credential, for: id)
      }
    }

    syncConfigs()
    saveServers()
    logger.info("Updated server: \(label ?? url, privacy: .public)")
  }

  /// Validates a new credential against the server without persisting anything.
  /// v6: login() authenticates (throws .totpRequired / .invalidCredentials).
  /// v5: login() is a no-op, so checkStatus() probes the token (throws
  /// .unauthorized for a wrong or missing token). The probe service is always
  /// logged out — including when the probe fails mid-way — so no server-side
  /// session leaks accumulate (v6 has a session limit).
  public func verifyCredential(id: UUID, credential: String) async throws {
    guard let config = servers.first(where: { $0.id == id }) else {
      throw PiholeError.unknown("Server not found")
    }
    guard let serverURL = URL(string: config.url) else {
      throw PiholeError.unknown("Invalid URL format")
    }
    let session = makeSession(trusting: serverURL)
    let probe = try serviceFactory.buildService(
      config: config,
      credential: credential,
      session: session,
      suite: suite
    )
    do {
      try await probe.login()
      _ = try await probe.checkStatus()
    } catch {
      await probe.logout()
      throw error
    }
    await probe.logout()
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
    _ existingService: any PiholeServiceProviding,
    id: UUID,
    url: String,
    credential: String?
  ) {
    let currentCredential = credential ?? (try? keychain.readCredential(for: id)) ?? ""
    let config = ServerConfig(
      id: id,
      label: existingService.label,
      url: url,
      version: existingService.version,
      isPasswordless: currentCredential.isEmpty
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

  /// Returns blocking status for all servers. Each entry carries the typed
  /// error when that server's check failed (after its own retries).
  public func getBlockingStatus() async -> [UUID: Result<BlockingStatus, PiholeError>] {
    let configs = servers
    let svcs = services
    return await withTaskGroup(of: (UUID, Result<BlockingStatus, PiholeError>).self) { group in
      for config in configs {
        let svc = svcs[config.id]
        let id = config.id
        group.addTask {
          guard let svc else { return (id, .failure(PiholeError.unknown("Server not found"))) }
          do {
            let status = try await svc.checkStatus()
            return (id, .success(status))
          } catch {
            let piholeError = error as? PiholeError ?? PiholeError.unknown(error.localizedDescription)
            return (id, .failure(piholeError))
          }
        }
      }
      var results: [UUID: Result<BlockingStatus, PiholeError>] = [:]
      for await (id, result) in group {
        results[id] = result
      }
      return results
    }
  }

  /// Single-server health check. Returns nil for an unknown server id.
  public func checkServer(id: UUID) async -> Result<BlockingStatus, PiholeError>? {
    guard let svc = services[id] else { return nil }
    do {
      let status = try await svc.checkStatus()
      return .success(status)
    } catch {
      let piholeError = error as? PiholeError ?? PiholeError.unknown(error.localizedDescription)
      if isCredentialFailure(piholeError) && !hasStoredCredential(id: id) {
        // No saved credential (never stored, or the keychain is unreadable):
        // surface "re-authenticate" instead of "password may have changed".
        return .failure(.missingCredential)
      }
      return .failure(piholeError)
    }
  }

  /// Whether the error means "the credential we tried was rejected" (as
  /// opposed to TOTP, rate limiting, or network problems).
  private func isCredentialFailure(_ error: PiholeError) -> Bool {
    switch error {
    case .invalidCredentials, .unauthorized:
      return true
    case .server(let code, _) where code == 401:
      return true
    default:
      return false
    }
  }

  /// Whether a real credential is in the keychain (false for password-less).
  private func hasStoredCredential(id: UUID) -> Bool {
    (try? keychain.readCredential(for: id)) != nil
  }

  /// Toggle blocking on all servers. Returns per-server success/failure.
  public func setBlocking(enabled: Bool, duration: TimeInterval?) async -> [UUID: Bool] {
    let configs = servers
    let svcs = services
    return await withTaskGroup(of: (UUID, Bool).self) { group in
      for config in configs {
        let svc = svcs[config.id]
        let id = config.id
        group.addTask {
          do {
            guard let svc else { return (id, false) }
            try await withRetry(.destructive) {
              try await svc.setBlocking(enabled: enabled, duration: duration)
            }
            return (id, true)
          } catch {
            return (id, false)
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
    let configs = servers
    let svcs = services
    return await withTaskGroup(of: (UUID, Result<Void, any Error>).self) { group in
      for config in configs {
        let svc = svcs[config.id]
        let id = config.id
        group.addTask {
          do {
            guard let svc else { return (id, .failure(PiholeError.unknown("Server not found"))) }
            try await withRetry(.destructive) {
              try await svc.unblockDomain(stripped, duration: duration)
            }
            return (id, .success(()))
          } catch {
            return (id, .failure(error))
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

  public func deleteDomain(_ domain: String) async {
    let serverList = servers
    let svcs = services
    let log = logger
    await withTaskGroup(of: Void.self) { group in
      for config in serverList {
        guard let service = svcs[config.id] else { continue }
        let label = config.label ?? config.url
        group.addTask {
          do {
            try await withRetry(.destructive) {
              try await service.deleteDomain(domain: domain)
            }
          } catch {
            log.warning(
              "deleteDomain failed on \(label): \(error.localizedDescription, privacy: .public)"
            )
          }
        }
      }
    }
  }

  public func getDomains() async throws -> [UUID: [DomainEntry]] {
    let serverList = servers
    let svcs = services
    let log = logger
    let collected: [(UUID, [DomainEntry])] = await withTaskGroup(
      of: (UUID, [DomainEntry])?.self
    ) { group in
      for config in serverList {
        guard let service = svcs[config.id] else { continue }
        let id = config.id
        let label = config.label ?? config.url
        group.addTask {
          do {
            let domains = try await service.getDomains()
            return (id, domains)
          } catch {
            log.warning(
              "getDomains failed on \(label): \(error.localizedDescription, privacy: .public)"
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
    let svcs = services
    let log = logger
    let allBlocked: [BlockedDomain] = await withTaskGroup(
      of: [BlockedDomain].self
    ) { group in
      for config in serverList {
        guard let service = svcs[config.id] else { continue }
        let label = config.label ?? config.url
        group.addTask {
          do {
            return try await service.getRecentBlocked(forClientIp: forClientIp, interval: interval)
          } catch {
            log.warning(
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
    let configs = servers
    let svcs = services
    return await withTaskGroup(of: (UUID, QuerySummary?).self) { group in
      for config in configs {
        let svc = svcs[config.id]
        let id = config.id
        group.addTask {
          do {
            guard let svc else { return (id, nil) }
            let summary = try await svc.getQuerySummary()
            return (id, summary)
          } catch {
            return (id, nil)
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
      // Build the service even without a stored credential (using an empty
      // one): the health check then fails as an auth error and the UI can
      // offer a "Re-authenticate" affordance instead of "unreachable".
      let storedCredential = try? keychain.readCredential(for: config.id)
      if !config.isPasswordless && storedCredential == nil {
        logger.warning("No credential found for server \(config.id), will prompt to re-authenticate")
      }
      let credential = config.isPasswordless ? "" : (storedCredential ?? "")
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
        return ServerConfig(
          id: svc.id,
          label: svc.label,
          icon: config.icon,
          url: svc.url,
          version: svc.version,
          isPasswordless: config.isPasswordless
        )
      }
      return config
    }
  }
}
