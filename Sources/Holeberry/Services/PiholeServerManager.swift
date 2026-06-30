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
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "server-manager")

  private var services: [UUID: PiholeServiceProtocol] = [:]

  init(keychain: KeychainManager = .shared, serviceFactory: PiholeServiceFactory = .shared) {
    self.keychain = keychain
    self.serviceFactory = serviceFactory
    self.servers = []
    self.combinedStatus = CombinedStatus()
    loadServers()
  }

  // MARK: - Server CRUD

  func addServer(label: String?, url: String, credential: String) async throws {
    guard servers.count < Self.maxServers else {
      throw PiholeError.unknown("Maximum of \(Self.maxServers) Pi-hole instances allowed")
    }

    guard URL(string: url) != nil else {
      throw PiholeError.unknown("Invalid URL format")
    }

    guard !credential.isEmpty else {
      throw PiholeError.unknown("Credential is required")
    }

    let version = try await testConnection(url: url, credential: credential)

    let config = ServerConfig(label: label, url: url, version: version)
    let rawService = serviceFactory.buildService(config: config, credential: credential)
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: rawService)

    servers.append(config)
    services[config.id] = decorator
    saveServers()

    try keychain.saveCredential(credential, for: config.id)

    logger.info("Added server: \(config.label ?? config.url, privacy: .public)")
  }

  func updateServer(id: UUID, label: String?, url: String, credential: String?, version: ServerVersion? = nil) {
    guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }

    if let service = services[id] {
      let oldURL = service.url

      if let label { service.label = label }
      service.url = url
      if let version { service.version = version }

      if url != oldURL {
        service.refreshSession(from: url)
      }
    } else {
      if let label { servers[idx].label = label }
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

  func addServerAfterTest(
    label: String?,
    url: String,
    version: ServerVersion,
    credential: String
  ) throws -> ServerConfig {
    guard servers.count < Self.maxServers else {
      throw PiholeError.unknown("Maximum of \(Self.maxServers) Pi-hole instances allowed")
    }
    let config = ServerConfig(label: label, url: url, version: version)
    let rawService = serviceFactory.buildService(config: config, credential: credential)
    let decorator = TemporaryUnblockPiholeServiceDecorator(service: rawService)
    servers.append(config)
    services[config.id] = decorator
    try keychain.saveCredential(credential, for: config.id)
    saveServers()
    logger.info("Added server after test: \(label ?? url, privacy: .public)")
    return config
  }

  func revertAddServer(id: UUID) {
    if let service = services.removeValue(forKey: id) {
      Task { await service.logout() }
    }
    servers.removeAll { $0.id == id }
    saveServers()
    try? keychain.deleteCredential(for: id)
    logger.info("Reverted server creation: \(id.uuidString, privacy: .public)")
  }

  // MARK: - Connection Testing

  func testConnection(url urlString: String, credential: String) async throws -> ServerVersion {
    guard let url = URL(string: urlString) else {
      throw PiholeError.unknown("Invalid URL format")
    }

    let hosts = Set(servers.compactMap { URL(string: $0.url)?.host } + [url.host].compactMap { $0 })
    let delegate = CertificateTrustDelegate(trustedHosts: hosts)
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    // 1. Try v6 auth first
    let authURL = url.appendingPathComponent("/api/auth")
    var authRequest = URLRequest(url: authURL)
    authRequest.httpMethod = "POST"
    authRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    authRequest.timeoutInterval = 15
    authRequest.httpBody = try Self.jsonEncoder.encode(["password": credential])

    let (authData, authResponse): (Data, URLResponse)
    do {
      (authData, authResponse) = try await session.data(for: authRequest)
    } catch {
      return try await detectV5Fallback(url: url, session: session)
    }

    guard let authHTTP = authResponse as? HTTPURLResponse else {
      return try await detectV5Fallback(url: url, session: session)
    }

    switch authHTTP.statusCode {
    case 200:
      let authManager = AuthManager(baseURL: url, session: session)
      let service = PiholeV6Service(
        id: UUID(),
        label: nil,
        url: urlString,
        version: .v6,
        baseURL: url,
        session: session,
        authManager: authManager,
        password: credential
      )
      _ = try await service.checkStatus()
      return .v6

    case 400:
      guard
        let json = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
        let errorObj = json["error"] as? [String: Any],
        let message = errorObj["message"] as? String,
        message.localizedCaseInsensitiveContains("2fa")
      else {
        return try await detectV5Fallback(url: url, session: session)
      }
      throw PiholeError.totpRequired

    case 401:
      throw PiholeError.unauthorized

    case 404:
      return try await detectV5Fallback(url: url, session: session)

    default:
      return try await detectV5Fallback(url: url, session: session)
    }
  }

  private func detectV5Fallback(url: URL, session: URLSession) async throws -> ServerVersion {
    let version = try await PiholeVersionDetector.detect(baseURL: url, session: session)
    return version
  }

  // MARK: - Status & Blocking

  func refreshStatuses() async {
    for (id, service) in services {
      guard let credential = try? keychain.readCredential(for: id) else { continue }
      do {
        let version = try await testConnection(url: service.url, credential: credential)
        service.version = version
      } catch {
        logger.warning(
          "refreshStatuses failed for \(service.label ?? service.url): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    syncConfigs()
    saveServers()
  }

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
    try await service.unblockDomain(domain, duration: duration)
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

  func getRecentBlocked(count: Int) async throws -> [String] {
    var allBlocked: [String] = []
    for config in servers {
      guard let service = services[config.id] else { continue }
      do {
        let blocked = try await service.getRecentBlocked(count: count)
        allBlocked.append(contentsOf: blocked)
      } catch {
        logger.warning(
          "getRecentBlocked failed on \(config.label ?? config.url): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    return allBlocked
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
    let configs: [ServerConfig] = Defaults[.servers]
    servers = configs

    for config in configs {
      guard let credential = try? keychain.readCredential(for: config.id) else {
        logger.warning("No credential found for server \(config.id), skipping")
        continue
      }
      let rawService = serviceFactory.buildService(config: config, credential: credential)
      let decorator = TemporaryUnblockPiholeServiceDecorator(service: rawService)
      services[config.id] = decorator
    }

    syncConfigs()
  }

  private func saveServers() {
    Defaults[.servers] = servers
  }

  private func syncConfigs() {
    servers = servers.map { config in
      if let svc = services[config.id] {
        return ServerConfig(id: svc.id, label: svc.label, url: svc.url, version: svc.version)
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
