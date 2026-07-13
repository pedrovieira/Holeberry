import Foundation

/// Creates ``AuthSessionProviding`` instances for a Pi-hole host.
///
/// Returns an auth session for v6 instances; throws for unsupported versions.
protocol AuthSessionFactory: Sendable {
  func makeSession(
    host: URL,
    password: String,
    urlSession: URLSession,
    piHoleVersion: ServerVersion
  ) throws -> AuthSessionProviding
}

struct ConcreteAuthSessionFactory: AuthSessionFactory {
  static let shared = ConcreteAuthSessionFactory()

  func makeSession(
    host: URL,
    password: String,
    urlSession: URLSession,
    piHoleVersion: ServerVersion
  ) throws -> AuthSessionProviding {
    guard piHoleVersion == .v6 else {
      throw PiholeError.unknown("Auth session is only supported for Pi-hole v6")
    }
    return AuthV6SessionProvider(host: host, password: password, urlSession: urlSession)
  }
}
