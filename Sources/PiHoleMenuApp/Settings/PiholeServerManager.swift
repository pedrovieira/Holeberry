import Defaults
import Foundation
import OSLog

@MainActor
final class PiholeServerManager: ObservableObject, ServerProviding {
  private static let maxServers = 2
  private static let jsonEncoder = JSONEncoder()

  static let shared = PiholeServerManager()

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
    guard servers.count < Self.maxServers else {
      throw PiholeError.unknown("Maximum of \(Self.maxServers) Pi-hole instances allowed")
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

  func testConnection(url urlString: String, credential: String) async throws -> PiholeServer.Version {
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
      // Network error during auth attempt — fall through to v5 probe
      return try await detectV5Fallback(url: url, session: session)
    }

    guard let authHTTP = authResponse as? HTTPURLResponse else {
      return try await detectV5Fallback(url: url, session: session)
    }

    switch authHTTP.statusCode {
    case 200:
      // v6 confirmed — verify credential works
      let authManager = AuthManager(baseURL: url, session: session)
      let service = PiholeV6Service(
        baseURL: url, session: session, authManager: authManager, password: credential
      )
      _ = try await service.checkStatus()
      return .v6

    case 400:
      // Pi-hole returns 400 when TOTP is required but not provided in the body
      if let json = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
         let errorObj = json["error"] as? [String: Any],
         let message = errorObj["message"] as? String,
         message.localizedCaseInsensitiveContains("2fa") {
        throw PiholeError.totpRequired
      }
      // Other 400 — not a v6 auth endpoint, fall through to v5 probe
      return try await detectV5Fallback(url: url, session: session)

    case 401:
      // Wrong password or invalid TOTP — either way, unauthorized
      throw PiholeError.unauthorized

    case 404:
      // No /api/auth endpoint — fall back to v5 probe
      return try await detectV5Fallback(url: url, session: session)

    default:
      return try await detectV5Fallback(url: url, session: session)
    }
  }

  private func detectV5Fallback(url: URL, session: URLSession) async throws -> PiholeServer.Version {
    let version = try await PiholeVersionDetector.detect(baseURL: url, session: session)
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

  func updateServerVersion(id: UUID, version: PiholeServer.Version) {
    guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
    servers[index].version = version
    saveServers()
  }

  func logoutAll() async {
    for (_, conn) in connections {
      if let authManager = conn.authManager {
        await authManager.logout()
      }
      conn.session.invalidateAndCancel()
    }
    connections.removeAll()
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

    var authManager: AuthManager?
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

  func perform<T>(
    for server: PiholeServer, block: (PiholeServiceProtocol) async throws -> T
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
      return try await block(service)
    case .v5:
      let service = PiholeV5Service(baseURL: url, session: conn.session, apiToken: credential)
      return try await block(service)
    }
  }

  private func loadServers() {
    servers = Defaults[.servers]
  }

  private func saveServers() {
    Defaults[.servers] = servers
  }
}

struct CombinedStatus {
  var totalQueries: Int = 0
  var totalBlocked: Int = 0
  var blockingEnabled: Bool = true
  var connectedInstanceCount: Int = 0
  var totalInstanceCount: Int = 0
}
