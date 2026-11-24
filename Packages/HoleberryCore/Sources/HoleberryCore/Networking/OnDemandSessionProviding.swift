import Foundation

/// Supplies the HTTP transport for an on-demand read.
///
/// This exists so an on-demand client can keep the production transport
/// policy in Core and still be tested without a network.
@MainActor
public protocol OnDemandSessionProviding {
  /// - Parameter trustedHosts: Configured hosts whose self-signed certificate
  ///   may be accepted. Other hosts use default TLS handling.
  func makeSession(trustedHosts: Set<String>) -> any HTTPRequestable
}

/// One short-lived session that trusts self-signed certificates for configured hosts.
///
/// This is the transport the widget uses: ephemeral configuration, no shared
/// cookie or cache state between fetches.
@MainActor
public struct EphemeralOnDemandSessionProvider: OnDemandSessionProviding {
  public init() {}

  public func makeSession(trustedHosts: Set<String>) -> any HTTPRequestable {
    let delegate = CertificateTrustDelegate(trustedHosts: trustedHosts)
    return URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
  }
}
