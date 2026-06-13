import Foundation
import OSLog

@MainActor
final class PiholeServerManager: ObservableObject {
  @Published var servers: [PiholeServer]
  @Published private(set) var combinedStatus: CombinedStatus

  private let keychain = KeychainManager.shared
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "server-manager")

  private struct ServerConnection {
    let session: URLSession
    let authManager: AuthManager?
  }

  private var connections: [UUID: ServerConnection] = [:]

  init() {
    self.servers = []
    self.combinedStatus = CombinedStatus()
    loadServers()
  }

  deinit {
    for conn in connections.values {
      conn.session.invalidateAndCancel()
    }
  }

  func addServer(label: String?, url: String, credential: String) async throws {
    guard servers.count < 2 else {
      throw PiholeError.unknown("Maximum of 2 Pi-hole instances allowed")
    }

    guard URL(string: url) != nil else {
      throw PiholeError.unknown("Invalid URL format")
    }

    guard !credential.isEmpty else {
      throw PiholeError.unknown("Password is required")
    }

    let version = try await testConnection(url: url, credential: credential)

    let server = PiholeServer(label: label, url: url, version: version)
    servers.append(server)
    saveServers()

    try keychain.saveCredential(credential, for: server.id)

    logger.info("Added server: \(server.label ?? server.url, privacy: .public)")
  }

  func updateServer(id: UUID, label: String?, url: String, credential: String?, version: PiholeServer.Version? = nil) {
    guard let index = servers.firstIndex(where: { $0.id == id }) else { return }

    let oldLabel = servers[index].label
    let oldUrl = servers[index].url
    let oldVersion = servers[index].version

    servers[index].label = label
    servers[index].url = url
    if let version {
      servers[index].version = version
    }

    if let credential, !credential.isEmpty {
      try? keychain.saveCredential(credential, for: id)
    }

    saveServers()
    logger.info("Updated server: \(label ?? url, privacy: .public)")

    let needsCleanup = label != oldLabel || url != oldUrl || credential != nil || version != oldVersion
    if needsCleanup {
      removeConnection(for: id)
    }
  }

  func deleteServer(id: UUID) {
    servers.removeAll { $0.id == id }
    saveServers()
    try? keychain.deleteCredential(for: id)
    removeConnection(for: id)
    logger.info("Deleted server: \(id.uuidString, privacy: .public)")
  }

  func addServerAfterTest(label: String?, url: String, version: PiholeServer.Version) throws -> PiholeServer {
    guard servers.count < 2 else {
      throw PiholeError.unknown("Maximum of 2 Pi-hole instances allowed")
    }
    let server = PiholeServer(label: label, url: url, version: version)
    servers.append(server)
    saveServers()
    logger.info("Added server after test: \(label ?? url, privacy: .public)")
    return server
  }

  func revertAddServer(id: UUID) {
    servers.removeAll { $0.id == id }
    saveServers()
    try? keychain.deleteCredential(for: id)
    removeConnection(for: id)
    logger.info("Reverted server creation: \(id.uuidString, privacy: .public)")
  }

  func testConnection(url: String, credential: String) async throws -> PiholeServer.Version {
    guard let url = URL(string: url) else {
      throw PiholeError.unknown("Invalid URL format")
    }

    let hosts = Set(servers.compactMap { URL(string: $0.url)?.host } + [url.host].compactMap { $0 })
    let delegate = CertificateTrustDelegate(trustedHosts: hosts)
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    let version = try await PiholeVersionDetector.detect(baseURL: url, session: session)

    switch version {
    case .v6:
      let authManager = AuthManager(baseURL: url, session: session)
      let service = PiholeV6Service(
        baseURL: url, session: session, authManager: authManager, password: credential
      )
      _ = try await service.checkStatus()

    case .v5:
      let service = PiholeV5Service(baseURL: url, session: session, apiToken: credential)
      _ = try await service.checkStatus()
    }

    return version
  }

  func refreshStatuses() async {
    for i in servers.indices {
      guard let credential = try? keychain.readCredential(for: servers[i].id) else { continue }
      do {
        let version = try await testConnection(url: servers[i].url, credential: credential)
        servers[i].version = version
      } catch {
        servers[i].version = nil
      }
    }
    saveServers()
  }

  func getBlockingStatus(for server: PiholeServer) async throws -> BlockingStatus {
    try await perform(for: server) { service in
      try await service.checkStatus()
    }
  }

  func setBlocking(for server: PiholeServer, enabled: Bool, duration: TimeInterval?) async throws {
    try await perform(for: server) { service in
      try await service.setBlocking(enabled: enabled, duration: duration)
    }
  }

  func reloadServers() {
    loadServers()
  }

  private func connection(for server: PiholeServer) -> ServerConnection {
    if let existing = connections[server.id] {
      return existing
    }

    let hosts = Set(servers.compactMap { URL(string: $0.url)?.host })
    let delegate = CertificateTrustDelegate(trustedHosts: hosts)
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)

    var authManager: AuthManager? = nil
    if server.version == .v6, let url = URL(string: server.url) {
      authManager = AuthManager(baseURL: url, session: session)
    }

    let conn = ServerConnection(session: session, authManager: authManager)
    connections[server.id] = conn
    return conn
  }

  private func removeConnection(for id: UUID) {
    guard let conn = connections.removeValue(forKey: id) else { return }
    if let authManager = conn.authManager {
      Task { await authManager.logout() }
    }
    conn.session.invalidateAndCancel()
  }

  private func perform<T>(
    for server: PiholeServer, operation: (PiholeServiceProtocol) async throws -> T
  ) async throws -> T {
    guard let url = URL(string: server.url) else {
      throw PiholeError.unknown("Invalid URL")
    }
    guard let credential = try? keychain.readCredential(for: server.id) else {
      throw PiholeError.unauthorized
    }
    guard let version = server.version else {
      throw PiholeError.unknown("Server version not detected")
    }

    let conn = connection(for: server)

    switch version {
    case .v6:
      guard let authManager = conn.authManager else {
        throw PiholeError.unknown("Auth manager not available")
      }
      let service = PiholeV6Service(
        baseURL: url, session: conn.session, authManager: authManager, password: credential
      )
      return try await operation(service)
    case .v5:
      let service = PiholeV5Service(baseURL: url, session: conn.session, apiToken: credential)
      return try await operation(service)
    }
  }

  private func loadServers() {
    let storage = ServerStorage()
    servers = storage.wrappedValue
  }

  private func saveServers() {
    var storage = ServerStorage()
    storage.wrappedValue = servers
  }
}

struct CombinedStatus {
  var totalQueries: Int = 0
  var totalBlocked: Int = 0
  var blockingEnabled: Bool = true
  var connectedInstanceCount: Int = 0
  var totalInstanceCount: Int = 0
}
