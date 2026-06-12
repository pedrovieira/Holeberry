import Foundation
import OSLog

@MainActor
final class PiholeServerManager: ObservableObject {
  @Published var servers: [PiholeServer]
  @Published private(set) var combinedStatus: CombinedStatus

  private let keychain = KeychainManager.shared
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "server-manager")

  init() {
    self.servers = []
    self.combinedStatus = CombinedStatus()
    loadServers()
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
  }

  func deleteServer(id: UUID) {
    servers.removeAll { $0.id == id }
    saveServers()
    try? keychain.deleteCredential(for: id)
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

    return try await PiholeVersionDetector.detect(baseURL: url, session: session)
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
