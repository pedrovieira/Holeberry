import Foundation

struct PiholeServiceFactory {
  static let shared = PiholeServiceFactory(
    authSessionFactory: ConcreteAuthSessionFactory.shared
  )

  private let authSessionFactory: AuthSessionFactory

  init(authSessionFactory: AuthSessionFactory) {
    self.authSessionFactory = authSessionFactory
  }

  @MainActor
  func buildService(
    config: ServerConfig,
    credential: String,
    session: URLSession
  ) throws -> PiholeServiceInternal {
    guard let url = URL(string: config.url) else {
      fatalError("Invalid URL in ServerConfig: \(config.url)")
    }

    let raw: PiholeServiceInternal
    switch config.version {
    case .v6:
      let authSession = try authSessionFactory.makeSession(
        host: url, password: credential, urlSession: session, piHoleVersion: config.version
      )
      raw = PiholeV6Service(
        id: config.id,
        label: config.label,
        url: config.url,
        version: config.version,
        baseURL: url,
        urlSession: session,
        authSession: authSession
      )
    case .v5:
      raw = PiholeV5Service(
        id: config.id,
        label: config.label,
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
