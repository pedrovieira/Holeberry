import Defaults
import Foundation
import OSLog

@MainActor
final class PiholeServerManager: ObservableObject {
  private static let maxServers = 2
  private static let jsonEncoder = JSONEncoder()

  static let shared = PiholeServerManager()

  @Published var servers: [ServerConfig] = []
  @Published private(set) var combinedStatus: CombinedStatus

  private let keychain: KeychainManager
  private let serviceFactory: PiholeServiceFactory
  private let versionDetector: PiholeVersionDetector
  private let suite: UserDefaults
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "server-manager")

  private var services: [UUID: PiholeServiceProtocol] = [:]

  init(
    keychain: KeychainManager = .shared,
    serviceFactory: PiholeServiceFactory = .shared,
    versionDetector: PiholeVersionDetector = .shared,
    suite: UserDefaults = .standard
  ) {
    self.keychain = keychain
    self.serviceFactory = serviceFactory
    self.versionDetector = versionDetector
    self.suite = suite
    self.servers = []
    self.combinedStatus = CombinedStatus()
    loadServers()
  }

  // MARK: - Server CRUD

  func addServer(label: String?, icon: String? = nil, url: String, credential: String) async throws {
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
    let service = serviceFactory.buildService(config: config, credential: credential, session: session)

    try await service.login()

    servers.append(config)
    services[config.id] = service
    saveServers()

    try keychain.saveCredential(credential, for: config.id)

    logger.info("Added server: \(config.label ?? config.url, privacy: .public)")
  }

  func updateServer(
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

  func deleteServer(id: UUID) {
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
    services[id] = serviceFactory.buildService(config: config, credential: currentCredential, session: session)
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

  func getBlockingStatus(for id: UUID) async throws -> BlockingStatus {
    guard let service = services[id] else {
      throw PiholeError.unknown("Server not found")
    }
    return try await service.checkStatus()
  }

  func setBlocking(for id: UUID, enabled: Bool, duration: TimeInterval?) async throws {
    guard let service = services[id] else {
      throw PiholeError.unknown("Server not found")
    }
    try await service.setBlocking(enabled: enabled, duration: duration)
  }

  func updateServerVersion(id: UUID, version: ServerVersion) {
    services[id]?.version = version
    syncConfigs()
    saveServers()
  }

  // MARK: - Session Management

  func logoutAll() async {
    for (_, service) in services {
      await service.logout()
    }
    services.removeAll()
    syncConfigs()
  }

  func reloadServers() {
    loadServers()
  }

  // MARK: - Typed Operations

  func unblockDomain(_ domain: String, duration: TimeInterval?, for serverID: UUID) async throws {
    guard let service = services[serverID] else { throw PiholeError.unknown("Server not found") }
    let stripped = domain.hasPrefix("www.") ? String(domain.dropFirst(4)) : domain
    try await service.unblockDomain(stripped, duration: duration)
  }

  func deleteDomain(_ domain: String) async {
    for config in servers {
      guard let service = services[config.id] else { continue }
      do {
        try await service.deleteDomain(domain: domain)
      } catch {
        logger.warning(
          "deleteDomain failed on \(config.label ?? config.url): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  func getDomains() async throws -> [UUID: [DomainEntry]] {
    var results: [UUID: [DomainEntry]] = [:]
    for config in servers {
      guard let service = services[config.id] else { continue }
      do {
        results[config.id] = try await service.getDomains()
      } catch {
        logger.warning(
          "getDomains failed on \(config.label ?? config.url): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    return results
  }

  func getRecentBlocked(forClientIp: String?, interval: DateInterval) async throws -> [BlockedDomain] {
    var allBlocked: [BlockedDomain] = []
    for config in servers {
      guard let service = services[config.id] else { continue }
      do {
        let blocked = try await service.getRecentBlocked(forClientIp: forClientIp, interval: interval)
        allBlocked.append(contentsOf: blocked)
      } catch {
        logger.warning(
          "getRecentBlocked failed on \(config.label ?? config.url): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    // Deduplicate by domain keeping the most recent timestamp, then sort DESC
    let deduped = Dictionary(grouping: allBlocked, by: \.domain)
      .compactMapValues { $0.max { $0.timestamp < $1.timestamp } }
      .values
      .sorted { $0.timestamp > $1.timestamp }
    return deduped
  }

  func getQuerySummary(for serverID: UUID) async throws -> QuerySummary {
    guard let service = services[serverID] else { throw PiholeError.unknown("Server not found") }
    return try await service.getQuerySummary()
  }

  // MARK: - Multi-server workflows

  func unblock(domain: String, duration: TimeInterval) async throws {
    guard !servers.isEmpty else { throw PiholeError.unknown("No configured Pi-hole instance") }
    var anySuccess = false
    var lastError: Error?

    for config in servers {
      do {
        try await unblockDomain(domain, duration: duration, for: config.id)
        anySuccess = true
      } catch {
        lastError = error
        logger.warning(
          "Unblock failed on \(config.label ?? config.url): \(error.localizedDescription, privacy: .public)"
        )
      }
    }

    guard anySuccess else { throw lastError ?? PiholeError.unknown("Failed to unblock on all servers") }
  }

  func addToAllowlist(domain: String) async {
    for config in servers {
      do {
        try await unblockDomain(domain, duration: nil, for: config.id)
      } catch {
        logger.warning(
          "Allowlist failed on \(config.label ?? config.url): \(error.localizedDescription, privacy: .public)"
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
      services[config.id] = serviceFactory.buildService(config: config, credential: credential, session: session)
    }

    syncConfigs()
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

struct CombinedStatus {
  var totalQueries: Int = 0
  var totalBlocked: Int = 0
  var blockingEnabled: Bool = true
  var connectedInstanceCount: Int = 0
  var totalInstanceCount: Int = 0
}
