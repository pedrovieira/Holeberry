import Foundation

/// Creates ``AuthSessionProviding`` instances for a Pi-hole host.
///
/// Returns an auth session for v6 instances; throws for unsupported versions.
public protocol AuthSessionFactory: Sendable {
  func makeSession(
    host: URL,
    password: String,
    urlSession: any HTTPRequestable,
    piHoleVersion: ServerVersion
  ) throws -> any AuthSessionProviding
}

public struct ConcreteAuthSessionFactory: AuthSessionFactory {
  public init() {}

  public func makeSession(
    host: URL,
    password: String,
    urlSession: any HTTPRequestable,
    piHoleVersion: ServerVersion
  ) throws -> any AuthSessionProviding {
    guard piHoleVersion == .v6 else {
      throw PiholeError.unknown("Auth session is only supported for Pi-hole v6")
    }
    return AuthV6SessionProvider(host: host, password: password, urlSession: urlSession)
  }
}
