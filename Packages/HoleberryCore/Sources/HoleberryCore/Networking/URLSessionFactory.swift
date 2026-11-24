import Foundation

/// Creates HTTP transports for one caller-owned session.
///
/// The caller chooses the configuration and every trusted host; the factory
/// attaches the shared certificate-trust policy. It never selects a session mode
/// on its own.
@MainActor
public protocol URLSessionFactory {
  /// Creates a transport owned by the caller, who must invalidate each returned
  /// session after use.
  func makeSession(
    configuration: URLSessionConfiguration,
    trustedHosts: Set<String>
  ) -> any HTTPRequestable
}

/// Production factory: the supplied configuration plus `CertificateTrustDelegate`.
@MainActor
public struct ConcreteURLSessionFactory: URLSessionFactory {
  public init() {}

  public func makeSession(
    configuration: URLSessionConfiguration,
    trustedHosts: Set<String>
  ) -> any HTTPRequestable {
    let delegate = CertificateTrustDelegate(trustedHosts: trustedHosts)
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
  }
}
