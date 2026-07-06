import Foundation

struct PiholeServiceFactory {
  static let shared = PiholeServiceFactory()

  @MainActor
  func buildService(config: ServerConfig, credential: String, session: URLSession) -> PiholeServiceInternal {
    guard let url = URL(string: config.url) else {
      fatalError("Invalid URL in ServerConfig: \(config.url)")
    }

    let raw: PiholeServiceInternal
    switch config.version {
    case .v6:
      let authManager = AuthManager(baseURL: url, session: session)
      raw = PiholeV6Service(
        id: config.id,
        label: config.label,
        icon: config.icon,
        url: config.url,
        version: config.version,
        baseURL: url,
        session: session,
        authManager: authManager,
        password: credential
      )
    case .v5:
      raw = PiholeV5Service(
        id: config.id,
        label: config.label,
        icon: config.icon,
        url: config.url,
        version: config.version,
        baseURL: url,
        session: session,
        apiToken: credential
      )
    }
    return TemporaryUnblockPiholeServiceDecorator(service: raw)
  }
}
