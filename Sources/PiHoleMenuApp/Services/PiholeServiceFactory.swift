import Foundation

struct PiholeServiceFactory {
  static let shared = PiholeServiceFactory()

  func buildService(
    version: PiholeServer.Version, url: URL, credential: String, session: URLSession
  ) -> PiholeServiceProtocol {
    switch version {
    case .v6:
      let authManager = AuthManager(baseURL: url, session: session)
      return PiholeV6Service(
        baseURL: url, session: session, authManager: authManager, password: credential
      )
    case .v5:
      return PiholeV5Service(baseURL: url, session: session, apiToken: credential)
    }
  }
}
