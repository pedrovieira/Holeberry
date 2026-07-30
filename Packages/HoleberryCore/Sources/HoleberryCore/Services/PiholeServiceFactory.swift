import Foundation

public struct PiholeServiceFactory {
  private let authSessionFactory: AuthSessionFactory
  private let htmlParser: PiholeV5HTMLParsing

  public init(
    authSessionFactory: AuthSessionFactory,
    htmlParser: PiholeV5HTMLParsing
  ) {
    self.authSessionFactory = authSessionFactory
    self.htmlParser = htmlParser
  }

  @MainActor
  public func buildService(
    config: ServerConfig,
    credential: String,
    session: any HTTPRequestable,
    suite: UserDefaults = .standard
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
        apiToken: credential,
        htmlParser: htmlParser
      )
    }
    return TemporaryUnblockPiholeServiceDecorator(service: raw, defaultsSuite: suite)
  }
}
