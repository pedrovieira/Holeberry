import Foundation

/// Builds a `PiholeServiceCommentAdding` for a given server configuration.
///
/// Extracted so `PiholeServerManager` depends on the seam and tests can inject
/// a mock; the production implementation is `ConcretePiholeServiceFactory`.
@MainActor
public protocol PiholeServiceFactory {
  func buildService(
    config: ServerConfig,
    credential: String,
    session: any HTTPRequestable,
    suite: UserDefaults
  ) throws -> any PiholeServiceCommentAdding
}

public struct ConcretePiholeServiceFactory: PiholeServiceFactory {
  private let authSessionFactory: any AuthSessionFactory
  private let htmlParser: any PiholeV5HTMLParsing

  public init(
    authSessionFactory: any AuthSessionFactory,
    htmlParser: any PiholeV5HTMLParsing
  ) {
    self.authSessionFactory = authSessionFactory
    self.htmlParser = htmlParser
  }

  public func buildService(
    config: ServerConfig,
    credential: String,
    session: any HTTPRequestable,
    suite: UserDefaults = .standard
  ) throws -> any PiholeServiceCommentAdding {
    guard let url = URL(string: config.url) else {
      fatalError("Invalid URL in ServerConfig: \(config.url)")
    }

    let raw: any PiholeServiceCommentAdding
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
