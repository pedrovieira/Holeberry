import Foundation

struct PiholeServiceFactory {
  static let shared = PiholeServiceFactory()

  func buildService(config: ServerConfig, credential: String) -> PiholeServiceProtocol {
    guard let url = URL(string: config.url) else {
      fatalError("Invalid URL in ServerConfig: \(config.url)")
    }
    let delegate = CertificateTrustDelegate(trustedHosts: [url.host].compactMap { $0 })
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)

    switch config.version {
    case .v6:
      let authManager = AuthManager(baseURL: url, session: session)
      return PiholeV6Service(
        id: config.id,
        label: config.label,
        url: config.url,
        version: config.version,
        baseURL: url,
        session: session,
        authManager: authManager,
        password: credential
      )
    case .v5:
      return PiholeV5Service(
        id: config.id,
        label: config.label,
        url: config.url,
        version: config.version,
        baseURL: url,
        session: session,
        apiToken: credential
      )
    }
  }
}
